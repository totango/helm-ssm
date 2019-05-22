# helm-ssm
A low-dependency tool used to retrieves and injects secrets from AWS SSM Parameter Store.

[![asciicast](https://asciinema.org/a/247712.svg)](https://asciinema.org/a/247712)


## Installation
```bash
$ helm plugin install https://github.com/totango/helm-ssm
```

## Overview
This plugin provides the ability to encode AWS SSM parameter paths into your
value files to store in version control or just generally less secure places.

During installation or upgrade, the parameters are replaced with their actual values
and passed on to Tiller.

Usage:
Simply use helm as you would normally, but add 'ssm' before any command,
the plugin will automatically search for values with the pattern:
```
{{ssm /path/to/parameter aws-region}}
```
and replace them with their decrypted value.

Optionally, if you have the same parameter for different profiles, you can set it like this:
```
{{ssm /path/to/parameter aws-region profile}}
```


>Note: You must have IAM access to the parameters you're trying to decrypt, and their KMS key.

>Note #2: Wrap the template with quotes, otherwise helm will confuse the brackets for json, and will fail rendering.

>Note #3: Currently, helm-ssm does not work when the value of the parameter is in the default chart values.

E.g:
```bash
$ helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml
```

value-file1.yaml:
```
secrets:
  haSharedSecret: "{{ssm /mgmt/docker-registry/shared-secret us-east-1}}"
  htpasswd: "{{ssm /mgmt/docker-registry/htpasswd us-east-1}}"
```

## Limitations
Since helm-ssm strives to be a no-dependencies tool, it is written using only shell commands, which introduces some limitations:

1. You cant have `|` in the parameter value - helm-ssm uses `sed` to replace the placeholders with the value of the parameter, and uses `|` as the delimiter, which means the value of the parameter can't also have it. As far as I know, other special characters are allowed.

## Testing
```
$ ./ssm.sh install tests/testchart/ --debug --dry-run -f tests/testchart/values.yaml
```
