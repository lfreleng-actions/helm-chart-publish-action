<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# ☸️ Helm Chart Publisher

Publishes Helm Charts to an OCI container repository.

## helm-chart-publish-action

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: "Publish Helm Charts"
    id: helm-publish
    uses: lfreleng-actions/helm-chart-publish-action@main
    with:
      username: ${{ secrets.REGISTRY_USERNAME }}
      password: ${{ secrets.REGISTRY_PASSWORD }}
      registry: "docker.io"
      organisation: "myorg"
      charts_path: "./chartstorage"
```

For some use cases, you may want to setup Helm plugins and perform other
environment setup tasks before invoking the action; below is an example:

```yaml
   - name: 'Build pre-requisites, install Helm plugins'
      id: pre-requisites
      shell: bash
      run: |
         # Build pre-requisites
         echo 'Running: git submodule update --init 💬'
         git submodule update --init
         echo 'Running: helm plugin installs 💬'
         plugin_dir='smo-install/onap_oom/kubernetes/helm/plugins/'
         helm plugin install "$plugin_dir/undeploy/"
         helm plugin install "$plugin_dir/deploy/"
         # Installation of helm-push fixes the error below
         # Error: unknown command "cm-push" for "helm"
         # yamllint disable-line rule:line-length
         helm plugin install https://github.com/chartmuseum/helm-push
         echo 'Listing Helm plugins 💬'
         helm plugin list
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name         | Required | Default                          | Description                                             |
| ------------ | -------- | -------------------------------- | ------------------------------------------------------- |
| username     | True     | -                                | Username for the repository                             |
| password     | True     | -                                | Password for the repository                             |
| registry     | False    | `docker.io`                      | Destination container registry                          |
| organisation | False    | `${{ github.repository_owner }}` | Organization/namespace in the container registry        |
| charts_path  | False    | `./chartstorage`                 | Path to the Helm charts directory                       |
| permit_fail  | False    | `false`                          | Allow action to fail without failing the workflow       |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name               | Description                             |
| ------------------ | --------------------------------------- |
| `published_files`  | List of files published                 |
| `failed_files`     | List of files that failed to publish    |
| `publication_count`| Number of files published               |
| `failed_count`     | Number of files that failed publishing  |

<!-- markdownlint-enable MD013 -->

## Implementation Details

<!-- markdownlint-disable MD013 -->

This action performs the following steps:

1. **Validation**: Validates required inputs and checks for Helm installation
   (Helm version 3.7.0 required for OCI support)
2. **Authentication**: Logs into the specified container registry using
   provided credentials
3. **Publishing**: Packages and pushes Helm chart files (.tgz) from the
   specified charts directory to the OCI registry

The action searches for `.tgz` files in the specified charts directory and
publishes each chart to the registry using the format:
`oci://{registry}/{organization}/{chart-name}`

<!-- markdownlint-enable MD013 -->

## Notes

<!-- markdownlint-disable MD013 -->

- Helm version 3.7.0 or higher required for OCI registry support
- Chart files are tarball `.tgz` files in the specified charts directory
- Extracts the chart name from each `.tgz` file using `helm show chart`
- Publishing failures permitted when using the `permit_fail` input/option

<!-- markdownlint-enable MD013 -->
