import argparse
import json
import subprocess


def main():
    parser = argparse.ArgumentParser(description="Print R-builds platforms as JSON.")
    parser.add_argument(
        'platforms',
        type=str,
        nargs='?',
        default='all',
        help='Comma-separated list of platforms. Specify "all" to use all platforms (the default).'
    )
    args = parser.parse_args()
    platforms = _get_platforms(which=args.platforms)
    print(json.dumps(platforms))


def _get_platforms(which='all'):
    supported_platforms = subprocess.check_output(['make', 'print-platforms'], text=True)
    supported_platforms = supported_platforms.split()
    if which == 'all':
        return supported_platforms
    platforms = which.split(',')
    platforms = [p for p in platforms if p in supported_platforms]
    return platforms


if __name__ == '__main__':
    main()
