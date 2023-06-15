#!/bin/bash

# Set this to a file path where the ip address will be stored
FILE_PATH=/path/to/file

# Cloudflare API endpoint
API="https://api.cloudflare.com/client/v4"

# The domain names you'd like updated
DOMAIN_NAMES=("domain-one.com" "domain-two.net" "domain-three.com")

# If using HashiCorp Vault (optional), comment or delete this var and uncomment/update the next several vars
API_TOKEN=xxxxx

# For HashiCorp Vault, create a key/value entry named cloudflare with client_token and api_token. Also create an appropriate approle with permissions to read it.
# VAULT=https://localhost:8200/v1
# ROLE_ID=xxxxxx
# Best not to pass the SECRET_ID here, but rather set as an environment variable
# SECRET_ID=
# VAULT_TOKEN=$(curl -s -k --request POST --data '{"role_id": "'${ROLE_ID}'", "secret_id": "'${SECRET_ID}'"}' $VAULT/auth/approle/login | jq -r '.auth.client_token')
# API_TOKEN=$(curl -s -k --header "X-Vault-Token:$VAULT_TOKEN" $VAULT/kv/data/cloudflare | jq -r '.data.data.api_token')

#
# Stop Editing
#

is_valid_ip() {
    local ip=$1
    local pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    local msg="Invalid IP address [$ip]"

    if [[ $ip =~ $pattern ]]; then
        local IFS='.'
        local -a octets=($ip)

        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                echo $msg
                return 1
            fi
        done

        return 0
    else
        echo $msg
        return 1
    fi
}

get_ip_http() {
    local ip=""
    
    ip=$(curl -s --max-time 5 https://api.ipify.org)
    
    if is_valid_ip "$ip"; then
        echo "$ip"
        return 0
    else
        return 1
    fi
}

get_ip_dns() {
    local ip=""
    
    ip=$(/var/packages/DNSServer/target/bin/dig +short ch txt whoami.Cloudflare @1.1.1.1 | tr -d '"')
    
    if is_valid_ip "$ip"; then
        echo "$ip"
        return 0
    else
        return 1
    fi
}

# Attempt to get external ip
if ! ip=$(get_ip_dns); then
    echo "Failed to retrieve external IP using DNS. Trying HTTP method..."
    
    if ! ip=$(get_ip_http); then
        echo "Failed to retrieve external IP using both methods."
        exit 1
    fi
fi

if [ "$ip" == `cat $FILE_PATH` ]; then
   echo "IP hasn't changed [$ip]"
   exit 0
fi

echo $ip > $FILE_PATH

ZONE_IDS=$(curl -s -X GET "${API}/zones" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[].id')

for ZONE_ID in ${ZONE_IDS}; do

    for DOMAIN_NAME in "${DOMAIN_NAMES[@]}"; do

        DNS_RECORDS=$(curl -s -X GET "${API}/zones/${ZONE_ID}/dns_records?name=${DOMAIN_NAME}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" | jq -r 'select(.result | length > 0)')

        if [ -n "${DNS_RECORDS}" ]; then
            
            RECORD_ID=$(echo "${DNS_RECORDS}" | jq -r '.result[] | select(.type == "A" and .name == "'${DOMAIN_NAME}'") | .id')
                
            RESPONSE=$(curl -s -X PUT "${API}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data '{
                    "type": "A",
                    "name": "'${DOMAIN_NAME}'",
                    "content": "'${ip}'",
                    "proxied": true
                }')

        	SUCCESS=$(echo "${RESPONSE}" | jq -r '.success')

            if [ "${SUCCESS}" = true ]; then
        		echo "DNS Record ID [${RECORD_ID}] for [${DOMAIN_NAME}] updated to [${ip}]"
            else
                echo "Failed to update DNS record for ${DOMAIN_NAME}"
            fi
        fi
    done
done
