import argparse
from yana import __version__

BANNER = r"""
   █████ █████   █████████   ██████   █████   █████████  
  ░░███ ░░███   ███░░░░░███ ░░██████ ░░███   ███░░░░░███ 
   ░░███ ███   ░███    ░███  ░███░███ ░███  ░███    ░███ 
    ░░█████    ░███████████  ░███░░███░███  ░███████████ 
     ░░███     ░███░░░░░███  ░███ ░░██████  ░███░░░░░███ 
      ░███     ░███    ░███  ░███  ░░█████  ░███    ░███ 
      █████    █████   █████ █████  ░░█████ █████   █████
     ░░░░░    ░░░░░   ░░░░░ ░░░░░    ░░░░░ ░░░░░   ░░░░░ 
                                                       
       A Framework for Event-Driven SNN Acceleration
  ───────────────────────────────────────────────────────
"""

parser = argparse.ArgumentParser(
    description="YANA Toolchain — event-driven SNN acceleration framework."
)
parser.add_argument(
    "--version", action="store_true", help="Print version and exit."
)
args = parser.parse_args()

if args.version:
    print(BANNER)
    print(f"  yana version {__version__}")
    print()
else:
    parser.print_help()
