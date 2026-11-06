#!/usr/bin/python3
"""仅验证 stdio 协议与故障语义，不调用模型，不证明真实 Agent 可用。"""
import json
import sys
import time


def read():
    return json.loads(sys.stdin.readline())


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


try:
    assert sys.argv[1:] == ["--disable", "hooks", "--disable", "apps", "--disable", "multi_agent", "-c", "notify=[]", "app-server", "--listen", "stdio://"]
    initialize = read()
    assert initialize["method"] == "initialize"
    tools_enabled = initialize["params"]["capabilities"]["experimentalApi"]
    emit({"id": 0, "result": {"userAgent": "fixture"}})
    assert read()["method"] == "initialized"
    assert read()["method"] == "config/read"
    emit({"id": 4, "result": {"config": {"mcp_servers": {"fixture": {}}, "apps": {}, "plugins": {}, "hooks": {}}}})
    request = read()
    assert request["method"] in ("thread/start", "thread/resume")
    params = request["params"]
    assert params["approvalPolicy"] == "never"
    assert params["config"]["mcp_servers"]["fixture"]["enabled"] is False
    assert params["config"]["apps"]["_default"]["enabled"] is False
    assert params["config"]["web_search"] == "disabled"
    if tools_enabled and request["method"] == "thread/start":
        assert [tool["name"] for tool in params["dynamicTools"]] == ["limeiot_read", "limeiot_command"]
        assert all(tool["type"] == "function" for tool in params["dynamicTools"])
    else:
        assert "dynamicTools" not in params
    thread = params.get("threadId", "thread-fixture")
    emit({"id": 1, "result": {"thread": {"id": thread}, "cwd": params["cwd"], "sandbox": {"type": "readOnly" if params["sandbox"] == "read-only" else "workspaceWrite"}, "approvalPolicy": "never"}})
    request = read()
    assert request["method"] == "turn/start"
    turn_params = request["params"]
    assert turn_params["threadId"] == thread
    assert turn_params["cwd"] == params["cwd"]
    assert turn_params["sandboxPolicy"]["networkAccess"] is False
    assert turn_params["approvalPolicy"] == "never"
    case = turn_params["input"][0]["text"]
    if case == "lost-before-turn-response":
        sys.exit(0)
    emit({"id": 2, "result": {"turn": {"id": "turn-fixture", "status": "inProgress"}}})
    if case == "iot-live":
        assert tools_enabled
        emit({"id": "read-device", "method": "item/tool/call", "params": {"threadId": thread, "turnId": "turn-fixture", "callId": "read-live", "tool": "limeiot_read", "arguments": {"device_id": "device-button"}}})
        read_result = read()["result"]
        assert read_result["success"] is True
        device = json.loads(read_result["contentItems"][0]["text"])
        assert device["device_id"] == "device-button"
        assert any(p["path"] == "light.power" and p["writable"] for p in device["properties"])
        emit({"id": "write-device", "method": "item/tool/call", "params": {"threadId": thread, "turnId": "turn-fixture", "callId": "write-live", "tool": "limeiot_command", "arguments": {"device_id": "device-button", "model_revision": device["model_revision"], "path": "light.power", "value": True}}})
        result = read()["result"]
        assert result["success"] is True
        assert json.loads(result["contentItems"][0]["text"])["status"] == "confirmed"
        emit({"method": "item/completed", "params": {"threadId": thread, "turnId": "turn-fixture", "item": {"type": "agentMessage", "id": "iot-result", "text": "LIMELINK_IOT_DEVICE_OK"}}})
        emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-fixture", "status": "completed"}}})
    elif case.startswith("tool-"):
        def tool(index, name="limeiot_read", call=None):
            arguments = {"device_id": "other" if case == "tool-wrong-target" else "lamp-test"}
            if name == "limeiot_command":
                arguments.update({"model_revision": "sha256:" + "a" * 64, "path": "light.power", "value": True})
            value = {"id": index, "method": "item/tool/call", "params": {"threadId": "foreign" if case == "tool-foreign-request" else thread, "turnId": "turn-fixture", "callId": call or "call-" + str(index), "tool": name, "arguments": arguments}}
            if case == "tool-namespace":
                value["params"]["namespace"] = "unapproved"
            emit(value)

        tool(0, "limeiot_command" if case == "tool-unknown" else "limeiot_read")
        if case == "tool-interrupt":
            request = read()
            assert request["method"] == "turn/interrupt"
            emit({"id": 3, "result": {}})
            emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-fixture", "status": "interrupted"}}})
        elif case == "tool-complete-pending":
            emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-fixture", "status": "completed"}}})
        elif case not in ("tool-reply-mismatch", "tool-bad-result"):
            reply = read()
            assert reply["id"] == 0
            if case in ("tool-disabled", "tool-foreign-request", "tool-namespace"):
                assert reply["error"]["code"] == -32601
            elif case == "tool-wrong-target":
                assert reply["result"]["success"] is False
            else:
                result = reply["result"]
                assert result["success"] is (case != "tool-unknown")
                assert result["contentItems"][0]["type"] == "inputText"
                assert json.loads(result["contentItems"][0]["text"])["device_id"] == "lamp-test"
            if case == "tool-read-command":
                tool(1, "limeiot_command")
                result = read()["result"]
                assert result["success"] is True
                assert json.loads(result["contentItems"][0]["text"])["command_id"] == "original-command"
            elif case == "tool-replayed":
                tool(1, call="call-0")
            elif case == "tool-id-replayed":
                tool(0, call="call-new")
            elif case == "tool-budget":
                for index in range(1, 17):
                    tool(index)
                    if index < 16:
                        assert read()["result"]["success"] is True
            emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-fixture", "status": "completed"}}})
        else:
            # 等待适配器拒绝非法回复并关闭 stdin。
            assert sys.stdin.readline() == ""
    elif case in ("interrupt", "interrupt-no-confirmation", "partial-line-interrupt"):
        if case == "partial-line-interrupt":
            sys.stdout.write('{"method":"item/completed",'); sys.stdout.flush()
        request = read()
        assert request["method"] == "turn/interrupt"
        assert request["params"] == {"threadId": thread, "turnId": "turn-fixture"}
        if case == "interrupt-no-confirmation":
            time.sleep(20)
        if case == "partial-line-interrupt":
            print('"params":{"threadId":"other","turnId":"other","item":{}}}', flush=True)
        emit({"id": 3, "result": {}})
        emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-fixture", "status": "interrupted"}}})
    elif case == "wrong-turn":
        emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "unrelated", "status": "completed"}}})
    elif case == "oversized-line":
        print("x" * 131073, flush=True)
    else:
        # 其他会话文字不得出现在当前会话。
        emit({"method": "item/completed", "params": {"threadId": "other", "turnId": "other", "item": {"type": "agentMessage", "id": "other", "text": "foreign"}}})
        # 不接受额外工具调用或权限请求。
        emit({"id": "server-request", "method": "item/tool/call", "params": {"threadId": thread}})
        assert read()["error"]["code"] == -32601
        emit({"method": "item/completed", "params": {"threadId": thread, "turnId": "turn-fixture", "item": {"type": "agentMessage", "id": "message-fixture", "text": "真实协议夹具" * 100}}})
        emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-fixture", "status": "completed"}}})
except Exception:
    sys.exit(1)
