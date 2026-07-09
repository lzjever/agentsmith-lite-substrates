#!/usr/bin/env python3
import importlib.util
import json
import sys
from pathlib import Path


sys.dont_write_bytecode = True
ROOT_DIR = Path(__file__).resolve().parents[1]
PROVIDER_PATH = ROOT_DIR / "manifests" / "local-openai" / "provider.py"


def load_provider():
    spec = importlib.util.spec_from_file_location("local_openai_provider", PROVIDER_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not load provider from {PROVIDER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tool_request(messages):
    return {
        "model": "local-openai-dev",
        "messages": messages,
        "tools": [
            {"type": "function", "function": {"name": "bash"}},
            {"type": "function", "function": {"name": "publish_file"}},
        ],
    }


def only_tool_call(response, name):
    choice = response["choices"][0]
    assert choice["finish_reason"] == "tool_calls"
    calls = choice["message"]["tool_calls"]
    assert len(calls) == 1
    call = calls[0]
    assert call["function"]["name"] == name
    return json.loads(call["function"]["arguments"])


def main():
    provider = load_provider()
    artifact_name = "agentsmith-lite-task-workflow-deadbeef.txt"
    marker = "AGENTSMITH_LITE_TASK_WORKFLOW_MARKER"
    prompt = "\n".join([
        "Deploy product workflow task artifact check.",
        f"Use bash in the current task home/cwd to create {artifact_name}.",
        f"The file content must include this exact marker on its own line: {marker}.",
        f"Then use the Botified publish_file tool to publish that file with filename {artifact_name}.",
        "Keep the response brief and do not include credentials or endpoint secret references.",
    ])

    bash_args = only_tool_call(
        provider.assistant_response(tool_request([{"role": "user", "content": prompt}])),
        "bash",
    )
    command = bash_args["command"]
    assert artifact_name in command, command
    assert marker in command, command

    publish_args = only_tool_call(
        provider.assistant_response(
            tool_request([
                {"role": "user", "content": prompt},
                {"role": "tool", "tool_call_id": provider.BASH_CALL_ID, "content": artifact_name},
            ])
        ),
        "publish_file",
    )
    assert publish_args["path"] == artifact_name
    assert publish_args["filename"] == artifact_name
    print("ok - local OpenAI provider follows workflow artifact prompt contract")


if __name__ == "__main__":
    main()
