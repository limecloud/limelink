#!/usr/bin/env python3
"""由专用systemd服务运行网关；凭据只从受限文件读取。"""
import json
import os
from pathlib import Path
import sys

root=Path(__file__).resolve().parent
state=Path(sys.argv[1]).resolve(strict=True)
settings=json.loads((state/"native.json").read_text())
os.environ.update({
    "LIMEIOT_LISTEN":"127.0.0.1:"+str(settings["http_port"]),
    "LIMEIOT_PUBLIC_ORIGIN":settings["origin"],
    "LIMEIOT_CONFIG":str(state/"config/gateway.json"),
    "LIMEIOT_DB":str(state/"data/gateway.sqlite"),
    "LIMEIOT_TOKEN_FILE":str(state/"secrets/owner-token"),
    "LIMEIOT_MQTT_HOST":"127.0.0.1",
    "LIMEIOT_MQTT_PORT":str(settings["plain_port"]),
    "LIMEIOT_MQTT_PASSWORD":(state/"secrets/gateway-password").read_text().strip(),
    "LIMEIOT_HOME_DIR":str(root/"home"),
})
os.execv(root/"bin/limeiot-gateway",[str(root/"bin/limeiot-gateway")])
