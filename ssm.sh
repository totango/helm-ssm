#!/usr/bin/env bash
set -eo pipefail

# A bunch of text colors for echoing
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NOC='\033[0m'

# Checks if a value exists in an array
# Usage: elementIn "some_value" "${VALUES[@]}"; [[ #? -eq 0 ]] && echo "EXISTS!" || echo "DOESNT EXIST! :("
function elementIn () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

function printUsage () {
    set -e
    cat <<EOF
AWS SSM parameter injection in Helm value files

This plugin provides the ability to encode AWS SSM parameter paths into your
value files to store in version control or just generally less secure places.

During installation or upgrade, the parameters are replaced with their actual values
and passed on to Tiller.

Usage:
Simply use helm as you would normally, but add 'ssm' before any command,
the plugin will automatically search for values with the pattern:

    {{ssm /path/to/parameter aws-region}}

and replace them with their decrypted value.
Note: You must have IAM access to the parameters you're trying to decrypt, and their KMS key.
Note #2: Wrap the template with quotes, otherwise helm will confuse the brackets for json, and will fail rendering.
Note #3: Currently, helm-ssm does not work when the value of the parameter is in the default chart values.


E.g:
helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml

value-file1.yaml:
---
secrets:
  haSharedSecret: "{{ssm /mgmt/docker-registry/shared-secret us-east-1}}"
  htpasswd: "{{ssm /mgmt/docker-registry/htpasswd us-east-1}}"
---
EOF
    exit 0
}


# Handle dependencies
# AWS cli
if ! [[ -x "$(command -v aws)" ]]; then
    echo -e "${RED}[ERROR] aws cli is not installed." >&2
    exit 1
fi


# get the first command (install\list\template\etc...)
cmd="$1"

# "helm ssm/helm ssm help/helm ssm -h/helm ssm --help"
if [[ $# -eq 0 || "$cmd" == "help" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
    printUsage
fi

# if the command is not "install" or "upgrade", or just a single command (no value files is a given in this case), pass the args to the regular helm command
if [[ $# -eq 1 || ( "$cmd" != "install" && "$cmd" != "upgrade" && "$cmd" != "template") ]]; then
    set +e # disable fail-fast
    helm "$*"
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[SSM]${NOC} Helm exited with a non 0 code - this is most likely not a problem with the SSM plugin, but a problem with Helm itself." >&2
    fi

    exit ${EXIT_CODE} # exit with the same error code as the command
fi


VALUE_FILES=() # An array of paths to value files
OPTIONS=() # An array of all the other options given
while [[ "$#" -gt 0 ]]
do
    case "$1" in
    -h|--help)
        echo "usage!" # TODO proper usage
        exit 0
        ;;
    -f|--values)
        if [ $# -gt 1 ]; then # if we werent given just an empty '-f' option
            VALUE_FILES+=($2) # then add the path to the array
        fi
        ;;
    *)
        # we go over each options, and if the option isnt a value file, we add it to the options array
        set +e # we turn off fast-fail because the check of if the array contains a value returns exit code 0 or 1 depending on the result
        elementIn "$1" "${VALUE_FILES[@]}"
        [[ $? -eq 1 ]] && OPTIONS+=($1)
        set -e # when we're finished with the check, we turn on fast-fail
        ;;
    esac
    shift
done

echo -e "${GREEN}[SSM]${NOC} Options: ${OPTIONS[@]}"
echo -e "${GREEN}[SSM]${NOC} Value files: ${VALUE_FILES[@]}"

set +e # we disable fail-dast because we want to give the user a proper error message in case we cant read the value file
MERGED_TEXT=""
for FILEPATH in "${VALUE_FILES[@]}"; do
    echo -e "${GREEN}[SSM]${NOC} Reading ${FILEPATH}"

    if [[ ! -f ${FILEPATH} ]]; then
        echo -e "${RED}[SSM]${NOC} Error: open ${FILEPATH}: no such file or directory" >&2
        exit 1
    fi

    VALUE=$(cat ${FILEPATH} 2> /dev/null) # read the content of the values file silently (without outputing an error in case it fails)
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[SSM]${NOC} Error: open ${FILEPATH}: failed to read contents" >&2
        exit 1
    fi

    VALUE=$(echo -e "${VALUE}" | sed s/\%/\%\%/g) # we turn single % to %% to escape percent signs
    printf -v MERGED_TEXT "${MERGED_TEXT}\n${VALUE}" # We concat the files together with a newline in between using printf and put output into variable MERGED_TEXT
done

PARAMETERS=$(echo -e "${MERGED_TEXT}" | grep -Eo "\{\{ssm [^\}]+\}\}") # Look for {{ssm /path/to/param us-east-1}} patterns, delete empty lines
PARAMETERS_LENGTH=$(echo "${PARAMETERS}" | grep -v '^$' | wc -l | xargs)
if [ "${PARAMETERS_LENGTH}" != 0 ]; then
    echo -e "${GREEN}[SSM]${NOC} Found $(echo "${PARAMETERS}" | grep -v '^$' | wc -l | xargs) parameters"
    echo -e "${GREEN}[SSM]${NOC} Parameters: \n${PARAMETERS[@]}"
else
    echo -e "${GREEN}[SSM]${NOC} No parameters were found, continuing..."
fi
echo -e "==============================================="


set +e
# using 'while' instead of 'for' allows us to use newline as a delimiter instead of a space
while read -r PARAM_STRING; do
    [ -z "${PARAM_STRING}" ] && continue # if parameter is empty for some reason

    CLEANED_PARAM_STRING=$(echo ${PARAM_STRING:2} | rev | cut -c 3- | rev) # we cut the '{{' and '}}' at the beginning and end
    PARAM_PATH=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 2) # {{ssm */param/path* us-east-1}}
    REGION=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 3) # {{ssm /param/path *us-east-1*}}
    PROFILE=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 4) # {{ssm /param/path us-east-1 *production*}}
    if [[ -n ${PROFILE}  ]]; then
       PROFILE_PARAM="--profile ${PROFILE}"  
    fi
    PARAM_OUTPUT="$(aws ssm get-parameter --with-decryption --name ${PARAM_PATH} --output text --query Parameter.Value --region ${REGION} $PROFILE_PARAM  2>&1)" # Get the parameter value or error message
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[SSM]${NOC} Error: Could not get parameter: ${PARAM_PATH}. AWS cli output: ${PARAM_OUTPUT}" >&2
        exit 1
    fi

    SECRET_TEXT="$(echo -e "${PARAM_OUTPUT}" | sed -e 's/[]\&\/$*.^[]/\\&/g')"
    MERGED_TEXT=$(echo -e "${MERGED_TEXT}" | sed "s|${PARAM_STRING}|${SECRET_TEXT}|g")
    sleep 0.5 # very basic rate limits
done <<< "${PARAMETERS}"

set +e
echo -e "${MERGED_TEXT}" | helm "${OPTIONS[@]}" --values -
EXIT_CODE=$?
if [[ ${EXIT_CODE} -ne 0 ]]; then
    echo -e "${RED}[SSM]${NOC} Helm exited with a non 0 code - this is most likely not a problem with the SSM plugin, but a problem with Helm itself." >&2
    exit ${EXIT_CODE}
fi
