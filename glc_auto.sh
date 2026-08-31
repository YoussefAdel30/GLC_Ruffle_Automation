#!/bin/bash

BASE_URL="http://10.179.9.32:8180"
LOGIN_URL="$BASE_URL/webservices/ERMCommonServices/UserManagement"
SEARCH_URL="$BASE_URL/graphviewer/service/search/searchByNodes"

USERNAME="ARCHC"
PASSWORD="fmsarch"

INPUT_JSON="$1"
LOG_FILE="$2"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

LOGIN_XML=$(cat <<EOF
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
xmlns:urn="http://services.facade.usermanagement.common.erm.hp.com/">
   <soapenv:Header/>
   <soapenv:Body>
      <urn:verifyCredential>
         <loginName>$USERNAME</loginName>
         <password>$PASSWORD</password>
         <userLocale>en_US</userLocale>
         <tzOffsetMillis>0</tzOffsetMillis>
      </urn:verifyCredential>
   </soapenv:Body>
</soapenv:Envelope>
EOF
)

LOGIN_RESPONSE=$(curl -sk -H "Content-Type: text/xml" --data "$LOGIN_XML" "$LOGIN_URL")

TOKEN=$(echo "$LOGIN_RESPONSE" | grep -oP '(?<=<validityToken>)[^<]+')

GRAPH_DEPTH=$(python3 -c "import json;print(json.load(open('$INPUT_JSON'))['graphDepth'])")
DATE_FROM=$(python3 -c "import json;print(json.load(open('$INPUT_JSON'))['dateFrom'])")
DATE_TO=$(python3 -c "import json;print(json.load(open('$INPUT_JSON'))['dateTo'])")
LINK_TYPE=$(python3 -c "import json;print(json.load(open('$INPUT_JSON'))['linkTypeCat'])")
DISP_TYPES=$(python3 -c "import json;print(json.load(open('$INPUT_JSON'))['dispTypes'])")
NODES_JSON=$(python3 -c "import json;print(json.dumps(json.load(open('$INPUT_JSON'))['nodes']))")

RESPONSE=$(curl -sk --http1.1 -X POST "$SEARCH_URL" \
  -H "validitytoken: $TOKEN" \
  -H "cookie: authdata=${TOKEN}%7CARCHC" \
  -F "uID=$(cat /proc/sys/kernel/random/uuid)" \
  -F "graphDepth=$GRAPH_DEPTH" \
  -F "nodesToSearch=$NODES_JSON" \
  -F "dispTypes=$DISP_TYPES" \
  -F "linkTypeCat=$LINK_TYPE" \
  -F "dateFrom=$DATE_FROM" \
  -F "dateTo=$DATE_TO"
)
# return ONLY JSON
echo "$RESPONSE"
exit 0