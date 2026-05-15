"""Coverage collector and reporter for mini-os unit tests.

Generates:
  - coverage/index.html    — HTML coverage report
  - coverage/summary.json  — machine-readable summary
  - coverage/badge.json    — shields.io endpoint for README badge
"""

import json
import sys
from pathlib import Path
from datetime import datetime, timezone


def generate_report(
    results: dict[str, dict],
    output_dir: str | Path = "coverage",
):
    """Generate coverage report files.

    Args:
        results: Dict of {routine_name: {total_addrs, hit_addrs, percentage, lines_total, lines_hit}}
        output_dir: Directory to write reports to.
    """
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    # Calculate overall stats
    total_addrs = sum(r.get("total_addrs", 0) for r in results.values())
    hit_addrs = sum(r.get("hit_addrs", 0) for r in results.values())
    overall_pct = (hit_addrs / total_addrs * 100) if total_addrs > 0 else 0

    # --- JSON summary ---
    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "overall_coverage": round(overall_pct, 1),
        "total_addresses": total_addrs,
        "hit_addresses": hit_addrs,
        "routines": {
            name: {
                "coverage": round(r.get("percentage", 0), 1),
                "total": r.get("total_addrs", 0),
                "hit": r.get("hit_addrs", 0),
            }
            for name, r in results.items()
        },
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    # --- Badge JSON (shields.io endpoint) ---
    color = "red" if overall_pct < 50 else "yellow" if overall_pct < 80 else "green"
    badge = {
        "schemaVersion": 1,
        "label": "coverage",
        "message": f"{overall_pct:.0f}%",
        "color": color,
    }
    (out / "badge.json").write_text(json.dumps(badge, indent=2), encoding="utf-8")

    # --- HTML report ---
    rows = ""
    for name, r in sorted(results.items()):
        pct = r.get("percentage", 0)
        filled = int(pct / 10)
        bar = "█" * filled + "░" * (10 - filled)
        rows += f"""        <tr>
            <td>{name}</td>
            <td>{r.get('total_addrs', 0)}</td>
            <td>{r.get('hit_addrs', 0)}</td>
            <td><code>{bar}</code> {pct:.0f}%</td>
        </tr>\n"""

    overall_filled = int(overall_pct / 10)
    overall_bar = "█" * overall_filled + "░" * (10 - overall_filled)

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>mini-os Coverage Report</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
               max-width: 800px; margin: 40px auto; padding: 0 20px;
               color: #24292e; background: #fff; }}
        h1 {{ border-bottom: 1px solid #e1e4e8; padding-bottom: 8px; }}
        .overall {{ font-size: 1.3em; margin: 20px 0; padding: 16px;
                    background: #f6f8fa; border-radius: 6px; }}
        table {{ border-collapse: collapse; width: 100%; margin-top: 20px; }}
        th, td {{ text-align: left; padding: 8px 12px; border-bottom: 1px solid #e1e4e8; }}
        th {{ background: #f6f8fa; font-weight: 600; }}
        code {{ font-family: 'SFMono-Regular', Consolas, monospace; }}
        .footer {{ margin-top: 40px; color: #6a737d; font-size: 0.85em; }}
    </style>
</head>
<body>
    <h1>mini-os Unit Test Coverage</h1>
    <div class="overall">
        Overall: <code>{overall_bar}</code> <strong>{overall_pct:.0f}%</strong>
        ({hit_addrs}/{total_addrs} instruction addresses)
    </div>
    <table>
        <tr><th>Routine</th><th>Total Addrs</th><th>Hit</th><th>Coverage</th></tr>
{rows}
    </table>
    <p class="footer">
        Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}
        · Tier 1 only (pure-logic unit tests via Unicorn Engine)
        · See <a href="https://github.com/AmbaneP/mini-os/blob/main/doc/TESTING.md">TESTING.md</a>
    </p>
</body>
</html>"""

    (out / "index.html").write_text(html, encoding="utf-8")
    return summary


def print_summary(summary: dict):
    """Print a markdown-formatted summary to stdout (for GitHub Actions Job Summary)."""
    print("## Unit Test Coverage\n")
    print(f"**Overall: {summary['overall_coverage']:.0f}%** "
          f"({summary['hit_addresses']}/{summary['total_addresses']} addresses)\n")
    print("| Routine | Coverage |")
    print("|---------|----------|")
    for name, r in sorted(summary["routines"].items()):
        pct = r["coverage"]
        filled = int(pct / 10)
        bar = "#" * filled + "-" * (10 - filled)
        print(f"| `{name}` | {bar} {pct:.0f}% |")
    print()


if __name__ == "__main__":
    # When run standalone, read summary.json and print markdown
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="coverage")
    parser.add_argument("--min-coverage", type=float, default=0)
    args = parser.parse_args()

    summary_path = Path(args.output) / "summary.json"
    if summary_path.exists():
        summary = json.loads(summary_path.read_text())
        print_summary(summary)
        if args.min_coverage > 0 and summary["overall_coverage"] < args.min_coverage:
            print(f"\n❌ Coverage {summary['overall_coverage']:.0f}% "
                  f"is below minimum {args.min_coverage:.0f}%")
            sys.exit(1)
    else:
        print("No summary.json found. Run pytest first.")
        sys.exit(1)
