# Keystone to Keystone federation with Juju

## Overview

This guide will configure Keystone to Keystone federation on a Juju OpenStack deployment. More info about Keystone federation can be found at:
* https://docs.openstack.org/keystone/ussuri/admin/federation/configure_federation.html
* https://docs.openstack.org/keystone/ussuri/admin/federation/introduction.html#keystone-to-keystone

This repository contains the Juju bundle (`bundle.yaml`) that can be deployed on Ubuntu Bionic (with `overlay-bionic.yaml`) or Focal (with `overlay-focal.yaml`). The bundle is minimal, it deploys only two Keystone instances into the same Juju model and configure one of them as a service provider (SP) and the other one as an identity provider (IdP).

## Deployment and Configuration Steps

1. Bootstrap a Juju controller. We'll be using the MAAS provider for this guide, and for the sake of simplicity, the Juju GUI is disabled:

    ```
    juju bootstrap home-maas --bootstrap-constraints "tags=juju-ctrl mem=2G" --no-gui
    ```

2. Deploy the Juju bundle. Pick the overlay for the Ubuntu release you want to use (Bionic or Focal), and make sure to adjust the constraints for the machine in the bundle to match your environment:

    ```
    juju deploy ./bundle.yaml --overlay ./overlay-bionic.yaml
    ```

3. Wait until the deployment finishes with all the units in idle state, and initialize the Vault (it will also generate a Vault root CA):

    ```
    ./initialize-vault.sh
    ```

4. Wait again until all the units are idle. After that, configure the Keystone IdP (at the moment this is not automated with Juju):

    * Before anything else, find out the addresses of the Keystone SP & Keystone IdP units via `juju run`:

        ```
        juju run --unit keystone-sp/leader 'network-get --bind-address public'
        10.114.2.6

        juju run --unit keystone-idp/leader 'network-get --bind-address public'
        10.114.2.4
        ```

    * SSH into the `keystone-idp/0` unit:

        ```
        juju ssh keystone-idp/0
        ```

    * Setup the `/etc/keystone/ssl` directory with the encryption `certfile` and `keyfile`. We will be re-using the ones already generated by Juju via the relation with the Vault charm:

        ```
        CERT_FILE=$(sudo find /etc/apache2/ssl/keystone -type f -name "cert_*")
        KEY_FILE=$(sudo find /etc/apache2/ssl/keystone -type f -name "key_*")
        sudo mkdir -p /etc/keystone/ssl
        sudo cp $CERT_FILE /etc/keystone/ssl/signing_cert.pem
        sudo cp $KEY_FILE /etc/keystone/ssl/signing_key.pem
        sudo chown -R keystone.keystone /etc/keystone/ssl
        ```

    * Edit the `keystone.conf` file:

        ```
        sudo vim /etc/keystone/keystone.conf
        ```

        and append the following section at the end of the file:

        ```
        [saml]
        idp_entity_id = https://KEYSTONE_IDP_ADDRESS:5000/v3/OS-FEDERATION/saml2/idp
        idp_sso_endpoint = https://KEYSTONE_IDP_ADDRESS:5000/v3/OS-FEDERATION/saml2/sso

        idp_organization_name = cloudbase_solutions
        idp_organization_display_name = Cloudbase Solutions SRL
        idp_organization_url = https://cloudbase.it
        idp_contact_company = cloudbase_solutions
        idp_contact_name = Ionut
        idp_contact_surname = Balutoiu
        idp_contact_email = ibalutoiu@cloudbasesolutions.com
        idp_contact_telephone = 555-555-5555
        idp_contact_type = technical

        idp_metadata_path = /etc/keystone/saml2_idp_metadata.xml

        certfile = /etc/keystone/ssl/signing_cert.pem
        keyfile = /etc/keystone/ssl/signing_key.pem

        relay_state_prefix = https://KEYSTONE_SP_ADDRESS/
        ```

        Make sure you replace `KEYSTONE_IDP_ADDRESS` with the Keystone IdP address, and `KEYSTONE_SP_ADDRESS` with the Keystone SP address (previously found via `juju run`).

        In this example, the Keystone SP address is `10.114.2.6` and the Keystone IdP address is `10.114.2.4`

        Optionally, you can update the IdP contact information.

        Save the changes, and exit vim.

    * Generate the IdP `metadata.xml` file:

        ```
        sudo bash -c "keystone-manage saml_idp_metadata > /etc/keystone/saml2_idp_metadata.xml"
        sudo chown keystone.keystone /etc/keystone/saml2_idp_metadata.xml
        ```

    * Restart the Apache2 service:

        ```
        sudo systemctl restart apache2
        ```

    * The Keystone IdP is complete now. Exit the SSH session to `keystone-idp/0`

5. Download the Keystone IdP `metadata.xml` from the IdP endpoint:

    ```
    IDP_ADDRESS=$(juju run --unit keystone-idp/leader 'network-get --bind-address public')
    curl -s -k -o idp-metadata.xml https://$IDP_ADDRESS:5000/v3/OS-FEDERATION/saml2/metadata
    ```

6. Attach the `idp-metadata.xml` file as a Juju resource to the `keystone-saml-mellon` charm:

    ```
    juju attach-resource keystone-saml-mellon idp-metadata=./idp-metadata.xml
    ```

    After units finish their hooks execution, you may notice that the `keystone-saml-mellon` charm is `BLOCKED` with status `'websso-fid-service-provider' missing`. Don't worry about it. Our bundle is minimal and it didn't deploy the OpenStack Dashboard component.

    Besides this, Keystone as an IdP doesn't support the SAML 2.0 WebSSO auth profile (as documented [here](https://docs.openstack.org/keystone/ussuri/admin/federation/configure_federation.html#configuring-metadata) for the `idp_sso_endpoint` config option).

    Right now, we need to link both Keystones via the Keystone API.

7. Create the service provider resource into the `keystone-idp` API:

    ```
    source ./openrc-idp.sh

    SP_ADDRESS=$(juju run --unit keystone-sp/leader 'network-get --bind-address public')

    openstack service provider create keystone-sp \
        --service-provider-url https://$SP_ADDRESS:5000/v3/OS-FEDERATION/identity_providers/keystone_idp/protocols/mapped/auth/mellon/paosResponse \
        --auth-url https://$SP_ADDRESS:5000/v3/OS-FEDERATION/identity_providers/keystone_idp/protocols/mapped/auth
    ```

8. Create the identity provider resource into the `keystone-sp` API, and setup the mapping for the federated users:

    ```
    source ./openrc-sp.sh

    IDP_ADDRESS=$(juju run --unit keystone-idp/leader 'network-get --bind-address public')

    DOMAIN_NAME="keystone_idp_domain"
    PROJECT_NAME="keystone_idp_project"
    REMOTE_ID="https://$IDP_ADDRESS:5000/v3/OS-FEDERATION/saml2/idp"
    IDP_NAME="keystone_idp"

    openstack domain create $DOMAIN_NAME
    openstack project create $PROJECT_NAME --domain $DOMAIN_NAME
    openstack identity provider create --remote-id $REMOTE_ID --domain $DOMAIN_NAME $IDP_NAME

    cat > /tmp/rules.json << EOF
    [
    {
        "local": [
        {
            "user": {
            "name": "{0}"
            },
            "domain": {
            "name": "$DOMAIN_NAME"
            },
            "projects": [
            {
                "name": "$PROJECT_NAME",
                "roles": [
                {
                    "name": "member"
                }
                ]
            }
            ]
        }
        ],
        "remote": [
        {
            "type": "MELLON_NAME_ID"
        }
        ]
    }
    ]
    EOF

    openstack mapping create --rules /tmp/rules.json "${IDP_NAME}_mapping"
    openstack federation protocol create mapped --mapping "${IDP_NAME}_mapping" --identity-provider $IDP_NAME
    ```

9. At this point, the configuration is ready. You can use the Keystone IdP to get a scoped token from the Keystone SP. Besides the usual `OS_*` environment variables needed to auth to the Keystone IdP, you need to set some extra env variables to get the scoped token (these should match the mapped values from the mapping previously created in the Keystone SP):

    ```
    source ./openrc-idp.sh

    export OS_SERVICE_PROVIDER=keystone-sp
    export OS_REMOTE_PROJECT_NAME=keystone_idp_project
    export OS_REMOTE_PROJECT_DOMAIN_NAME=keystone_idp_domain

    openstack --debug --insecure token issue
    ```

    This should properly return a token that has access to the resources from the Keystone SP cloud.

## Known Issues

In case you get the following trackback when requesting a scoped token from Keystone SP:

```
Request returned failure status: 400
Bad Request (HTTP 400)
Traceback (most recent call last):
  ...
  ...
  (Python traceback details)
  ...
  ...
keystoneauth1.exceptions.http.BadRequest: Bad Request (HTTP 400)
clean_up IssueToken: Bad Request (HTTP 400)
END return value: 1
```

check the Keystone SP error log:

```
juju ssh keystone-sp/0 'tail -n 10 /var/log/apache2/error.log'
```

and if you encounter the following log:

```
[Sun Oct 04 20:31:34.382188 2020] [auth_mellon:error] [pid 13417:tid 140068891068160] [client 10.114.2.6:34698] Error processing ECP authn response. Lasso error: [101] Signature element not found., SAML Response: StatusCode1="urn:oasis:names:tc:SAML:2.0:status:Success", StatusCode2="(null)", StatusMessage="(null)"
```

then you are impacted by the following distro bug: https://bugs.launchpad.net/ubuntu/+source/lasso/+bug/1897117

To fix this, you need to update the liblasso3 dependency from the `keystone-sp/0` unit. You can do that via the following commands (execute them as `root` after you ssh into `keystone-sp/0` unit):

```
wget http://ftp.br.debian.org/debian/pool/main/l/lasso/liblasso3_2.6.1-1_amd64.deb

mkdir tmp
dpkg-deb -R liblasso3_2.6.1-1_amd64.deb tmp
cp tmp/usr/lib/liblasso.so.3.13.1 /usr/lib/

ln -sf liblasso.so.3.13.1 /usr/lib/liblasso.so.3

systemctl restart apache2
```

After this, re-execute the `openstack token issue` command and it should properly get the scoped token.