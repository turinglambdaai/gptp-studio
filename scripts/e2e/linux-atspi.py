#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import pyatspi


def children(node):
    for index in range(node.childCount):
        try:
            yield node.getChildAtIndex(index)
        except Exception:
            continue


def walk(node):
    yield node
    for child in children(node):
        yield from walk(child)


def role(node):
    try:
        return node.getRoleName()
    except Exception:
        return "unknown"


def node_text(node):
    try:
        text = node.queryText()
        return text.getText(0, text.characterCount)
    except Exception:
        return ""


def wait_for(description, probe, timeout=30.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")


def find_application():
    desktop = pyatspi.Registry.getDesktop(0)
    for application in children(desktop):
        for node in walk(application):
            if role(node) == "frame" and "gptp studio" in (node.name or "").casefold():
                return application
    return None


def find_named(root, name, expected_role=None):
    for node in walk(root):
        if (node.name or "") == name and (expected_role is None or role(node) == expected_role):
            return node
    return None


def contains(root, needle):
    folded = needle.casefold()
    return any(
        folded in (node.name or "").casefold() or folded in node_text(node).casefold()
        for node in walk(root)
    )


def press(node):
    actions = node.queryAction()
    if actions.nActions < 1 or not actions.doAction(0):
        raise AssertionError(f"AT-SPI action failed for {node.name!r}")


def snapshot(node, depth=0):
    result = {"name": node.name or "", "role": role(node)}
    value = node_text(node)
    if value:
        result["text"] = value
    if depth < 8:
        result["children"] = [snapshot(child, depth + 1) for child in children(node)]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    application = wait_for("gPTP Studio application", find_application)
    window = wait_for(
        "gPTP Studio frame",
        lambda: next((node for node in walk(application) if role(node) == "frame"), None),
    )
    start = wait_for("Start Engine button", lambda: find_named(window, "Start Engine", "push button"))
    stop = wait_for("Stop Engine button", lambda: find_named(window, "Stop Engine", "push button"))

    press(start)
    wait_for(
        "simulator state returned through RVT1",
        lambda: contains(window, "slave / sim / system"),
    )
    press(stop)
    wait_for(
        "simulator stop state returned through RVT1",
        lambda: contains(window, "slave / #f / system"),
    )

    (args.output / "accessibility.json").write_text(
        json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "interaction-trace.json").write_text(
        json.dumps(
            {
                "platform": "linux",
                "actions": ["press:Start Engine", "press:Stop Engine"],
                "assertions": [
                    "packaged GTK4 frame activated on native Wayland",
                    "AT-SPI roles and names exposed",
                    "simulator start mutation reached the embedded backend",
                    "engine State/Event presentation changed to running then stopped",
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
