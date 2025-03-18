#!/usr/bin/env python3
import json
import os
from tabulate import tabulate
import requests
import time
import argparse
import yaml
import re
from datetime import datetime
import subprocess

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

def load_table_cache(run_id):
    """Load previously processed package results with their full table entries"""
    cache_dir = f"runs/{run_id}/cache"
    succeeded_file = f"{cache_dir}/table_succeeded.txt"
    failed_file = f"{cache_dir}/table_failed.txt"
    verified_bbs_file = f"{cache_dir}/verified_bbs.txt"
    
    cache = {
        "succeeded": [],
        "failed": [],
        "handled_packages": set(),  # Only packages with valid BBS status
        "verified_bbs": set()       # Packages with verified BBS status
    }
    
    os.makedirs(cache_dir, exist_ok=True)
    
    if os.path.exists(succeeded_file):
        with open(succeeded_file) as f:
            for line in f:
                if line.strip():
                    entry = eval(line.strip())
                    cache["succeeded"].append(entry)
                    # Only consider handled if BBS status was found
                    pkg_name = entry[0][1:entry[0].find(']')]  # Extract name from markdown link
                    if entry[3] != "Not Found":
                        cache["handled_packages"].add(pkg_name)
    
    if os.path.exists(failed_file):
        with open(failed_file) as f:
            for line in f:
                if line.strip():
                    entry = eval(line.strip())
                    cache["failed"].append(entry)
                    # Only consider handled if BBS status was found
                    pkg_name = entry[0][1:entry[0].find(']')]  # Extract name from markdown link
                    if entry[3] != "Not Found":
                        cache["handled_packages"].add(pkg_name)
    
    # Load packages with verified BBS status
    if os.path.exists(verified_bbs_file):
        with open(verified_bbs_file) as f:
            cache["verified_bbs"] = set(line.strip() for line in f if line.strip())
    
    return cache

def save_table_cache(run_id, cache):
    """Save table entries and handled packages list"""
    cache_dir = f"runs/{run_id}/cache"
    succeeded_file = f"{cache_dir}/table_succeeded.txt"
    failed_file = f"{cache_dir}/table_failed.txt"
    handled_file = f"{cache_dir}/handled_packages.txt"
    verified_bbs_file = f"{cache_dir}/verified_bbs.txt"
    
    with open(succeeded_file, 'w') as f:
        for entry in cache["succeeded"]:
            f.write(f"{entry}\n")
    
    with open(failed_file, 'w') as f:
        for entry in cache["failed"]:
            f.write(f"{entry}\n")
    
    with open(handled_file, 'w') as f:
        for pkg in sorted(cache["handled_packages"]):
            f.write(f"{pkg}\n")
    
    with open(verified_bbs_file, 'w') as f:
        for pkg in sorted(cache["verified_bbs"]):
            f.write(f"{pkg}\n")

def extract_pkg_name(entry):
    """Extract package name from markdown link in table entry"""
    return entry[0][1:entry[0].find(']')]

def get_bioc_version(run_id):
    """Gets bioc version from version file"""
    with open(f"runs/{run_id}/bioc_version", "r") as f:
        return f.read().strip()

def save_cycle_summary(run_id, bioc_version, success_count, failed_count, unprocessed_count):
    """
    Save a summary of the cycle to a dedicated file
    
    Args:
        run_id: The run identifier
        bioc_version: Bioconductor version
        success_count: Number of successful packages
        failed_count: Number of failed packages
        unprocessed_count: Number of unprocessed packages
    """
    summary_path = f"runs/{run_id}/summary.md"
    
    # Get cycle timing information
    start_time = run_id.replace("-", " ", 2).replace("-", ":")
    end_time = "In Progress"
    status = "In Progress"
    
    # Update with completion time if available
    if os.path.exists(f"runs/{run_id}/cycle_complete_time"):
        with open(f"runs/{run_id}/cycle_complete_time") as tf:
            end_time = tf.read().strip()
            status = "Complete"
    
    # Get total packages in repo index if available
    total_packages = ""
    if os.path.exists(f"runs/{run_id}/indexed_packages_count"):
        with open(f"runs/{run_id}/indexed_packages_count") as f:
            total_packages = f.read().strip()
    
    # Write summary
    with open(summary_path, "w") as f:
        f.write(f"run_id: {run_id}\n")
        f.write(f"start_time: {start_time}\n")
        f.write(f"end_time: {end_time}\n")
        f.write(f"bioc_version: {bioc_version}\n")
        f.write(f"successful: {success_count}\n")
        f.write(f"failed: {failed_count}\n")
        f.write(f"total_packages: {total_packages}\n")
        f.write(f"status: {status}\n")
    
    print(f"Cycle summary saved to {summary_path}")

def main(run_id):
    print(f"Starting README update for run {run_id}")
    
    # Load package info and version
    with open(f"runs/{run_id}/biocdeps.json") as f:
        packages = json.load(f)
    bioc_version = get_bioc_version(run_id)
    cache = load_table_cache(run_id)
    
    print(f"Found {len(packages)} total packages in Bioconductor {bioc_version}")
    print(f"Previously documented {len(cache['handled_packages'])} packages")
    print(f"Packages with verified BBS status: {len(cache['verified_bbs'])}")
    
    # Get current status of all packages
    success_log = f"runs/{run_id}/logs/successful-packages.txt"
    successful = set()
    if os.path.exists(success_log):
        with open(success_log) as f:
            successful = {line.strip() for line in f if line.strip()}
    
    failed_dir = f"runs/{run_id}/logs"
    failed = {pkg for pkg in packages if os.path.exists(f"{failed_dir}/{pkg}/build-fail.log")}
    
    # Process only unhandled packages
    new_packages = (successful | failed) - {
        extract_pkg_name(entry) for entries in [cache["succeeded"], cache["failed"]]
        for entry in entries
    }
    print(f"Found {len(new_packages)} new packages to document")
    
    # Only check BBS status for:
    # 1. New packages
    # 2. Packages with previous "Not Found" status that weren't verified
    need_bbs_check = set()
    
    # Add new packages
    need_bbs_check.update(new_packages)
    
    # Add packages with "Not Found" that aren't verified
    for entries in [cache["succeeded"], cache["failed"]]:
        for entry in entries:
            pkg = extract_pkg_name(entry)
            if entry[3] == "Not Found" and pkg not in cache["verified_bbs"]:
                need_bbs_check.add(pkg)
    
    print(f"Found {len(need_bbs_check)} packages needing BBS status check")
    
    # Update existing entries that need BBS recheck
    for entries in [cache["succeeded"], cache["failed"]]:
        for entry in entries:
            pkg = extract_pkg_name(entry)
            if pkg in need_bbs_check and pkg not in new_packages:
                print(f"Checking BBS status for {pkg}...")
                bbs = get_bbs_status(pkg, bioc_version)
                if bbs != "Not Found":
                    entry[3] = bbs  # Update BBS status
                    cache["handled_packages"].add(pkg)
                    cache["verified_bbs"].add(pkg)  # Mark as verified
                elif pkg in cache["verified_bbs"]:
                    # If previously verified but now not found, keep it verified
                    # but update the status to current "Not Found"
                    entry[3] = bbs
    
    # Process new packages
    for pkg in sorted(new_packages):
        pkg_url = f"https://bioconductor.org/packages/{bioc_version}/bioc/html/{pkg}.html"
        pkg_link = f"[{pkg}]({pkg_url})"
        
        if pkg in successful:
            print(f"Checking BBS status for {pkg}...")
            log_path = f"runs/{run_id}/logs/{pkg}/build-success.log"
            log_link = f"[Log]({log_path})"
            bbs = get_bbs_status(pkg, bioc_version)
            cache["succeeded"].append([pkg_link, "Built", log_link, bbs])
            if bbs != "Not Found":
                cache["handled_packages"].add(pkg)
                cache["verified_bbs"].add(pkg)  # Mark as verified
        
        elif pkg in failed:
            print(f"Analyzing failure for {pkg}...")
            log_path = f"runs/{run_id}/logs/{pkg}/build-fail.log"
            log_link = f"[Log]({log_path})"
            with open(f"{failed_dir}/{pkg}/build-fail.log") as f:
                log_content = f.read()
            bbs = get_bbs_status(pkg, bioc_version)
            reasons = check_failure_reason(log_content)
            cache["failed"].append([pkg_link, "Failed", log_link, bbs, "\n".join(reasons)])
            if bbs != "Not Found":
                cache["handled_packages"].add(pkg)
                cache["verified_bbs"].add(pkg)  # Mark as verified
    
    # Save updated cache
    save_table_cache(run_id, cache)
    
    # Build final tables including cached entries
    tables = {
        "succeeded": cache["succeeded"],
        "failed": cache["failed"],
        "unprocessed": []
    }
    
    # Add remaining packages as unprocessed
    existing_pkgs = {
        extract_pkg_name(entry) 
        for entries in [tables["succeeded"], tables["failed"]]
        for entry in entries
    }
    
    for pkg in sorted(packages):
        if pkg not in existing_pkgs:
            pkg_url = f"https://bioconductor.org/packages/{bioc_version}/bioc/html/{pkg}.html"
            pkg_link = f"[{pkg}]({pkg_url})"
            tables["unprocessed"].append([pkg_link, "Unprocessed"])
    
    # Write README
    print("\nWriting README.md...")
    readme_path = f"runs/{run_id}/README.md"
    with open(readme_path, "w") as f:
        f.write(f"# Bioconductor {bioc_version} Binary Building Status\n\n")
        f.write(f"**Run ID:** {run_id}\n\n")
        
        # Add cycle timing information
        cycle_start = run_id.replace("-", " ", 2).replace("-", ":")  # Convert ID to datetime
        if os.path.exists(f"runs/{run_id}/cycle_complete_time"):
            with open(f"runs/{run_id}/cycle_complete_time") as tf:
                cycle_end = tf.read().strip()
                f.write(f"**Cycle Duration:** {cycle_start} EST → {cycle_end}\n\n")
        
        f.write("## Summary\n\n")
        f.write(f"- {len(tables['succeeded'])} packages built successfully\n")
        f.write(f"- {len(tables['failed'])} packages failed to build\n")
        f.write(f"- {len(tables['unprocessed'])} packages not yet processed\n")
        
        # Add indexed package count if available
        if os.path.exists(f"runs/{run_id}/indexed_packages_count"):
            with open(f"runs/{run_id}/indexed_packages_count") as f_count:
                indexed_count = f_count.read().strip()
                f.write(f"- {indexed_count} total packages in repository index\n")

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

    # Save cycle summary for this run
    save_cycle_summary(
        run_id,
        bioc_version,
        len(tables['succeeded']),
        len(tables['failed']),
        len(tables['unprocessed'])
    )

    print(f"\nREADME written to {readme_path}")
    print(f"Summary:")
    print(f"- {len(tables['succeeded'])} built")
    print(f"- {len(tables['failed'])} failed")
    print(f"- {len(tables['unprocessed'])} unprocessed")
    print(f"- {len(cache['verified_bbs'])} packages have verified BBS status")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", help="Current run ID")
    args = parser.parse_args()
    main(args.run_id)
