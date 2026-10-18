"""Neúspěšné a zopakované UI testy z výsledků xcodebuild (vstup: `xcresulttool get test-results tests`)."""
import json, sys
d = json.load(sys.stdin)
def walk(nodes):
    for n in nodes:
        if n.get("nodeType") == "Test Case":
            runs = [c for c in n.get("children", []) if c.get("nodeType") == "Repetition"]
            if n.get("result") != "Passed" or len(runs) > 1:
                print(f"- {n.get('name')}: {n.get('result')}" + (f" (pokusů {len(runs)})" if runs else ""))
                for c in n.get("children", []):
                    for f in c.get("children", []) if c.get("nodeType") == "Repetition" else [c]:
                        if f.get("nodeType") == "Failure Message":
                            print(f"    {f.get('name')}")
        walk(n.get("children", []))
walk(d.get("testNodes", []))
