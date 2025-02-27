#!/usr/bin/env python3
import json
import os
from tabulate import tabulate
import requests
import time
import argparse
import yaml
import re

def get_container_version(container_file):
    """Gets bioc version from container tag"""
    with open(container_file, "r") as f:
        container = f.read().strip()
    return container.split(":")[-1]

def check_cran_archived(pkg):
    """Checks if a package has been archived on CRAN"""
    cranurl = f"https://cran.r-project.org/web/packages/{pkg}/index.html"
    try:
        r = requests.get(cranurl, timeout=10)
        retries = 0
        while retries <= 5 and r.status_code != 200:
            r = requests.get(cranurl, timeout=10)
            retries += 1
            time.sleep(2)
        if r.status_code == 200:
            crantext = r.content.decode("utf-8")
            for search in ["Archived on", "Removed on"]:
                if search in crantext:
                    archivetext = crantext[crantext.find(search):].split('\n')[0]
                    return f"[CRAN Package '{pkg}']({cranurl}) {archivetext.lower()}"
    except (requests.exceptions.RequestException, UnicodeDecodeError):
        pass
    return None

def get_bbs_status(pkg, bioc_version):
    """Get current BBS build status for package"""
    bbsurl = f"https://bioconductor.org/checkResults/{bioc_version}/bioc-LATEST/{pkg}"
    statusurl = f"{bbsurl}/raw-results/nebbiolo2/buildsrc-summary.dcf"
    try:
        r = requests.get(statusurl, timeout=10)
        retries = 0
        while retries <= 5 and r.status_code != 200:
            r = requests.get(statusurl, timeout=10)
            retries += 1
            time.sleep(2)
        if r.status_code == 200:
            try:
                bbs_summary = r.content.decode("utf-8")
                status_line = next((line for line in bbs_summary.split('\n') if line.startswith('Status:')), '')
                if status_line:
                    status = status_line.split(':', 1)[1].strip()
                    return f"[{status}]({bbsurl})"
            except Exception:
                pass
    except (requests.exceptions.RequestException, UnicodeDecodeError):
        pass
    return "Not Found"

def check_failure_reason(log_content):
    """Extract all possible failure reasons from log file"""
    reasons = []
    # More comprehensive error patterns with all quote types
    patterns = [
        (r"there is no package called [\"'“”‘’]([^\"'“”‘’]+)[\"'“”‘’]", "Missing R dependency"),
        (r"ERROR: dependencies? [\"'“”‘’]([^\"'“”‘’]+)[\"'“”‘’] (?:is|are) not available", "Missing dependency"),
        (r"ERROR: package [\"'“”‘’]([^\"'“”‘’]+)[\"'“”‘’] (?:is|was) not found", "Package not found"),
        (r"ERROR: System command error.*?:\n\s*([^\n]+)", "System command failed"),
        (r"Installation failed:[\r\n]+\s*([^\r\n]+)", "Installation failed"),
        (r"error: command .*? failed with exit status \d+[\r\n]+\s*([^\r\n]+)", "Command error"),
        (r"error: Error installing package.*?:\n\s*([^\n]+)", "Installation error"),
        (r"configure: error:.*?([^\n]+)", "Configure error"),
        (r"ERROR:\s+compilation failed for package.*?([^\n]+)", "Compilation failed")
    ]
    
    for pattern, msg in patterns:
        matches = re.findall(pattern, log_content, re.IGNORECASE | re.MULTILINE)
        for match in matches:
            reason = f"{msg}: {match}"
            reasons.append(reason)
            # Check CRAN status for failed dependency
            if any(x in msg.lower() for x in ["dependency", "package"]):
                archived = check_cran_archived(match.strip())
                if archived:
                    reasons.append(archived)
    
    if not reasons:
        # Check for common error keywords
        error_keywords = [
            "error:", "Error:", "ERROR:", 
            "failed", "Failed", "FAILED",
            "cannot find", "not found",
            "could not", "unable to"
        ]
        for line in log_content.split('\n'):
            if any(kw in line for kw in error_keywords):
                reasons.append(line.strip())
                break
        
        if not reasons:
            reasons.append("Build failed with unknown error")
    
    return reasons

def load_cached_results(run_id):
    """Load previously processed package results"""
    handled_file = f"runs/{run_id}/cache/handled_packages.txt"
    
    handled_packages = set()
    os.makedirs(f"runs/{run_id}/cache", exist_ok=True)
    
    # Load packages we've already handled in README
    if os.path.exists(handled_file):
        with open(handled_file) as f:
            handled_packages.update(line.strip() for line in f if line.strip())
    
    return handled_packages

def save_handled_packages(run_id, handled_packages):
    """Save list of packages we've processed for README"""
    handled_file = f"runs/{run_id}/cache/handled_packages.txt"
    with open(handled_file, 'w') as f:
        for pkg in sorted(handled_packages):
            f.write(f"{pkg}\n")

def main(run_id):
    print(f"Starting README update for run {run_id}")
    
    # Load package info and version
    with open(f"runs/{run_id}/biocdeps.json") as f:
        packages = json.load(f)
    bioc_version = get_container_version(f"runs/{run_id}/CONTAINER_BASE_IMAGE.bioc")
    handled_packages = load_cached_results(run_id)
    
    print(f"Found {len(packages)} total packages in Bioconductor {bioc_version}")
    print(f"Previously documented {len(handled_packages)} packages")
    
    # Initialize tables
    tables = {
        "succeeded": [],
        "failed": [],
        "unprocessed": []
    }
    
    # Get current status of all packages
    success_log = f"runs/{run_id}/logs/successful-packages.txt"
    successful = set()
    if os.path.exists(success_log):
        with open(success_log) as f:
            successful = {line.strip() for line in f if line.strip()}
    
    # Find failed packages
    failed = set()
    failed_dir = f"runs/{run_id}/logs"
    for pkg in packages:
        if os.path.exists(f"{failed_dir}/{pkg}/build-fail.log"):
            failed.add(pkg)
    
    # Process only unhandled packages
    new_packages = (successful | failed) - handled_packages
    print(f"Found {len(new_packages)} new packages to document")
    
    for pkg in sorted(new_packages):
        pkg_url = f"https://bioconductor.org/packages/{bioc_version}/bioc/html/{pkg}.html"
        pkg_link = f"[{pkg}]({pkg_url})"
        
        if pkg in successful:
            print(f"Checking BBS status for {pkg}...")
            log_path = f"runs/{run_id}/logs/{pkg}/build-success.log"
            log_link = f"[Log]({log_path})"
            bbs = get_bbs_status(pkg, bioc_version)
            tables["succeeded"].append([pkg_link, "Built", log_link, bbs])
            handled_packages.add(pkg)
        
        elif pkg in failed:
            print(f"Analyzing failure for {pkg}...")
            log_path = f"runs/{run_id}/logs/{pkg}/build-fail.log"
            log_link = f"[Log]({log_path})"
            with open(f"{failed_dir}/{pkg}/build-fail.log") as f:
                log_content = f.read()
            bbs = get_bbs_status(pkg, bioc_version)
            reasons = check_failure_reason(log_content)
            tables["failed"].append([pkg_link, "Failed", log_link, bbs, "\n".join(reasons)])
            handled_packages.add(pkg)
    
    # Add remaining packages as unprocessed
    for pkg in sorted(packages):
        if pkg not in handled_packages:
            pkg_url = f"https://bioconductor.org/packages/{bioc_version}/bioc/html/{pkg}.html"
            pkg_link = f"[{pkg}]({pkg_url})"
            tables["unprocessed"].append([pkg_link, "Unprocessed"])
    
    # Save updated handled packages list
    save_handled_packages(run_id, handled_packages)
    
    # Write README
    print("\nWriting README.md...")
    with open("README.md", "w") as f:
        f.write(f"# Bioconductor {bioc_version} Binary Building Status\n\n")
        f.write(f"**Run ID:** {run_id}\n\n")
        f.write("## Summary\n\n")
        f.write(f"- {len(tables['succeeded'])} packages built successfully\n")
        f.write(f"- {len(tables['failed'])} packages failed to build\n")
        f.write(f"- {len(tables['unprocessed'])} packages not yet processed\n")
        
        if tables["failed"]:
            f.write(f"\n## Failed Builds ({len(tables['failed'])})\n")
            f.write(tabulate(tables["failed"], 
                ["Package", "Status", "Log", "BBS Status", "Failure Reasons"], 
                tablefmt="github"))
        
        if tables["succeeded"]:
            f.write(f"\n\n## Successfully Built ({len(tables['succeeded'])})\n")
            f.write(tabulate(tables["succeeded"], 
                ["Package", "Status", "Log", "BBS Status"], 
                tablefmt="github"))
        
        if tables["unprocessed"]:
            f.write(f"\n\n## Not Yet Processed ({len(tables['unprocessed'])})\n")
            f.write(tabulate(tables["unprocessed"], 
                ["Package", "Status"], 
                tablefmt="github"))

    print("\nREADME update complete")
    print(f"Summary:")
    print(f"- {len(tables['succeeded'])} built")
    print(f"- {len(tables['failed'])} failed")
    print(f"- {len(tables['unprocessed'])} unprocessed")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", help="Current run ID")
    args = parser.parse_args()
    main(args.run_id)
