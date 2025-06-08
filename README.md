# dump1090-fa_to_InfluxDB
dump1090-faのAVR(30001)からのBaseStationデータをInfluxDBのInlineProtocolに変換して，InfluxDBに書き込むBashスクリプト+永続化用のsystemdサービスファイル

## 構成
![dump1090-to-influxdb](https://github.com/user-attachments/assets/7de0c4d7-40e4-4e34-9a91-41963a2c2be2)

## 依存関係
- GNU netcat
- GNU sed
- curl
- sed
- (systemd)
