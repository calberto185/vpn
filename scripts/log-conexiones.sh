#!/bin/bash

STATUS_FILE="/var/log/openvpn/status.log"
LOG_FILE="/var/log/openvpn/openvpn.log"
LOG_OUTPUT="/var/log/openvpn/conexiones.json"
TMP_JSON="/tmp/ipinfo.json"

touch "$LOG_OUTPUT"
touch "$TMP_JSON"

CURRENT_DAY=$(date "+%Y-%m-%d")

while true; do
    NEW_DAY=$(date "+%Y-%m-%d")

    # 🧹 Limpieza diaria
    if [[ "$NEW_DAY" != "$CURRENT_DAY" ]]; then
        echo "[]" > "$LOG_OUTPUT"
        CURRENT_DAY="$NEW_DAY"
        echo "🧹 Limpieza diaria ejecutada: $(date)"
    fi

    if [[ -f "$STATUS_FILE" ]]; then
        echo "[" > "$LOG_OUTPUT"

        gawk -F',' -v logfile="$LOG_FILE" -v tmpjson="$TMP_JSON" '
        BEGIN {
            # Extraer plataforma por IP (ej: 94.25.179.86 -> ios)
            while ((getline line < logfile) > 0) {
                if (line ~ /peer info: IV_PLAT=/) {
                    if (match(line, /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+ .*IV_PLAT=([a-zA-Z0-9_-]+)/, arr)) {
                        plat[arr[1]] = arr[2]
                    }
                }
            }
            close(logfile)
        }

        /^Common Name/ { next }
        NF == 5 {
            user = $1
            ip_port = $2
            received = $3
            sent = $4
            connected = $5

            split(ip_port, ip_parts, ":")
            ip = ip_parts[1]

            # Geolocalización con archivo temporal
            cmd = "curl -s ipinfo.io/" ip "/json?token=fd40487236b339 > " tmpjson
            system(cmd)

            country = "desconocido"
            city = "desconocido"

            while ((getline line < tmpjson) > 0) {
                gsub(/[\r\n]/, "", line)
                if (line ~ /"country":/) {
                    match(line, /"country"[ ]*:[ ]*"([^"]+)"/, c)
                    if (c[1] != "") country = c[1]
                }
                if (line ~ /"city":/) {
                    match(line, /"city"[ ]*:[ ]*"([^"]+)"/, d)
                    if (d[1] != "") city = d[1]
                }
            }
            close(tmpjson)

            device = (ip in plat) ? plat[ip] : "desconocido"

            printf "  {\n"
            printf "    \"usuario\": \"%s\",\n", user
            printf "    \"ip\": \"%s\",\n", ip
            printf "    \"recibidos\": %s,\n", received
            printf "    \"enviados\": %s,\n", sent
            printf "    \"dispositivo\": \"%s\",\n", device
            printf "    \"pais\": \"%s\",\n", country
            printf "    \"ciudad\": \"%s\",\n", city
            printf "    \"conectadoDesde\": \"%s\"\n", connected
            printf "  },\n"
        }
        ' "$STATUS_FILE" | sed '$ s/},$/}/' >> "$LOG_OUTPUT"

        echo "]" >> "$LOG_OUTPUT"
    fi

    sleep 30
done
