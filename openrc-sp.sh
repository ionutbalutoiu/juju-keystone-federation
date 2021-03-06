for param in $(env | awk 'BEGIN {FS="="} /^OS_/ {print $1;}' | paste -sd ' '); do
   unset $param
done

ROOT_CA="/tmp/root-ca.crt"
KEYSTONE_IP=$(juju run --unit keystone-sp/leader -- 'network-get --bind-address public')
ADMIN_PASSWORD=$(juju run --unit keystone-sp/leader 'leader-get admin_passwd')

juju run --unit vault/leader 'leader-get root-ca' > $ROOT_CA 2>/dev/null

export OS_AUTH_PROTOCOL=https
export OS_CACERT=${ROOT_CA}
export OS_AUTH_URL=${OS_AUTH_PROTOCOL:-http}://${KEYSTONE_IP}:5000/v3
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASSWORD}
export OS_USER_DOMAIN_NAME=admin_domain
export OS_PROJECT_DOMAIN_NAME=admin_domain
export OS_PROJECT_NAME=admin
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
# Swift needs this
export OS_AUTH_VERSION=3
# Gnocchi needs this
export OS_AUTH_TYPE=password
