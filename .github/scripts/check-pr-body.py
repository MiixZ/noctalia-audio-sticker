#!/usr/bin/env python3
"""Check a rendered pull request description against the community template.

The community repository ships the enforcement script that runs on every pull
request. Reusing it here means a tag cannot publish a description that would be
rejected later.
"""
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import sys


def load_enforcer(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("enforce_pr_template", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("body", type=pathlib.Path)
    parser.add_argument("enforcer", type=pathlib.Path)
    args = parser.parse_args()

    module = load_enforcer(args.enforcer)
    body = args.body.read_text(encoding="utf-8")
    missing = module.missing_requirements(body, require_completed=True)
    if missing:
        for item in missing:
            print(f"error: missing from the pull request description: {item}", file=sys.stderr)
        return 1

    print("Pull request description satisfies the template.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
