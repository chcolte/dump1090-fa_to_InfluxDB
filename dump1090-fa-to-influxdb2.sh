#!/bin/bash

# --- 設定項目 ---
DUMP1090_HOST="192.168.1.30"
DUMP1090_PORT="30003"

INFLUXDB_URL="http://localhost:8086" # InfluxDB v2.x API endpoint
INFLUXDB_ORG="your-organization"     # InfluxDB v2.x 組織名
INFLUXDB_BUCKET="your-bucket"        # InfluxDB v2.x バケット名
INFLUXDB_TOKEN="your-API-token"      # InfluxDB v2.x API トークン

MEASUREMENT_NAME="adsb_messages"
# --- 設定項目ここまで ---

# InfluxDB v2.x
WRITE_URL="${INFLUXDB_URL}/api/v2/write?org=${INFLUXDB_ORG}&bucket=${INFLUXDB_BUCKET}&precision=ns"
AUTH_HEADER="Authorization: Token ${INFLUXDB_TOKEN}"

echo "Starting dump1090 to InfluxDB script..."
echo "Dump1090 Host: ${DUMP1090_HOST}:${DUMP1090_PORT}"
echo "InfluxDB Write URL: ${WRITE_URL}"
echo "Organization Name: ${INFLUXDB_ORG}"
echo "Bucket Name: ${INFLUX_BUCKET}"
echo "Measurement Name: ${MEASUREMENT_NAME}"

# TCP接続→データ処理でループ
while true; do
    nc -N -w 5 "${DUMP1090_HOST}" "${DUMP1090_PORT}" | while IFS= read -r line; do
        # BaseStation形式のデータを1行パース
        # MSG,TransmissionType,SessionID,AircraftID,HexIdent,FlightID,DateGen,TimeGen,DateLog,TimeLog,Callsign,Altitude,GroundSpeed,Track,Latitude,Longitude,VerticalRate,Squawk,Alert,Emergency,SPI,IsOnGround
        #  1      2             3          4          5        6        7       8       9       10      11       12       13          14    15       16        17           18      19    20        21  22
        IFS=',' read -r msg_type trans_type sid aid hex_ident fid date_gen time_gen date_log time_log callsign alt gs trk lat lon vr squawk alert emg spi gnd <<< "$line"
        # 必要なデータが含まれるMSGタイプか確認 (例: MSG,1 と MSG,3 は位置情報を含むことが多い)
        if [ "$msg_type" != "MSG" ] || { [ "$trans_type" != "1" ] && [ "$trans_type" != "3" ]; }; then
            continue
        fi

        # ICAO (HexIdent) が空の場合はスキップ
        if [ -z "$hex_ident" ]; then
            continue
        fi

        # タイムスタンプの生成 (BaseStationデータの日時を使用し、ナノ秒単位のUnixタイムスタンプに変換)
        # GNU date が必要です。macOS の date では %N が使えないので注意。
        ts_str="${date_gen} ${time_gen}"
        # 'YYYY/MM/DD HH:MM:SS.mmm' を 'YYYY-MM-DD HH:MM:SS.mmm' に変換
        formatted_ts=$(echo "$ts_str" | sed 's/\//-/g')
        timestamp_ns=$(date -u -d "$formatted_ts" "+%s%N" 2>/dev/null)

        if [ -z "$timestamp_ns" ]; then
            # タイムスタンプのパースに失敗した場合、現在の時刻を使用
            timestamp_ns=$(date +%s%N)
            echo "Warning: Could not parse timestamp '$ts_str' from data. Using current system time." >&2
        fi

        # InfluxDB ラインプロトコルの構築
        # タグセット（icao+もしコールサインも取得できていたらコールサインもタグに含める）
        tags="icao=${hex_ident}"
        if [ -n "$callsign" ]; then
            # コールサインに含まれる可能性のある特殊文字をエスケープ 
            safe_callsign=$(echo "$callsign" | sed -e 's/[, =]/\\&/g')
            tags="${tags},callsign=${safe_callsign}"
        fi

        # フィールドセット
        fields=""
        if [ -n "$alt" ]; then fields="${fields}altitude=${alt}i,"; fi
        if [ -n "$gs" ]; then fields="${fields}ground_speed=${gs},"; fi # 浮動小数点
        if [ -n "$trk" ]; then fields="${fields}track=${trk},"; fi      # 浮動小数点
        if [ -n "$lat" ]; then fields="${fields}latitude=${lat},"; fi    # 浮動小数点
        if [ -n "$lon" ]; then fields="${fields}longitude=${lon},"; fi  # 浮動小数点
        if [ -n "$vr" ]; then fields="${fields}vertical_rate=${vr}i,"; fi
        if [ -n "$squawk" ]; then fields="${fields}squawk=\"${squawk}\","; fi # 文字列
        if [ -n "$alert" ]; then fields="${fields}alert=$( [ "$alert" == "1" ] && echo true || echo false ),"; fi
        if [ -n "$emg" ]; then fields="${fields}emergency=$( [ "$emg" == "1" ] && echo true || echo false ),"; fi
        if [ -n "$spi" ]; then fields="${fields}spi=$( [ "$spi" == "1" ] && echo true || echo false ),"; fi
        if [ -n "$gnd" ]; then fields="${fields}on_ground=$( [ "$gnd" == "1" ] && echo true || echo false ),"; fi
        fields="${fields}msg_type=${trans_type}i" # 最後のフィールドなのでカンマなし

        # ラインプロトコル文字列完成
        line_protocol="${MEASUREMENT_NAME},${tags} ${fields} ${timestamp_ns}"

        # curl を使って InfluxDB にデータをPOST
        echo "Sending: $line_protocol" # デバッグ用
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -XPOST "${WRITE_URL}" \
            ${AUTH_HEADER:+--header "${AUTH_HEADER}"} \
            --data-binary "${line_protocol}")

        if [ "$http_code" -ne 204 ]; then
            echo "Error: Failed to write data to InfluxDB. HTTP status: $http_code. Data: $line_protocol" >&2
        fi
        echo "return code: ${http_code}"

    done

    echo "TCP connection to ${DUMP1090_HOST}:${DUMP1090_PORT} lost or nc exited. Reconnecting in 5 seconds..." >&2
    sleep 5
done
