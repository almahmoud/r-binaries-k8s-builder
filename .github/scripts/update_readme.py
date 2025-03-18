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

# Track the last successful BBS node
CURRENT_BBS_NODE = "nebbiolo2"  # Default starting node

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
    """Get current BBS build status for package, trying different BBS nodes if needed"""
    global CURRENT_BBS_NODE
    
    # Define both possible BBS nodes
    bbs_nodes = ["nebbiolo1", "nebbiolo2"]
    
    # Try the current node first
    bbsurl = f"https://bioconductor.org/checkResults/{bioc_version}/bioc-LATEST/{pkg}"
    statusurl = f"{bbsurl}/raw-results/{CURRENT_BBS_NODE}/buildsrc-summary.dcf"
    
    try:
        r = requests.get(statusurl, timeout=10)
        # If we get a 404, try the other node
        if r.status_code == 404:
            print(f"  404 from {CURRENT_BBS_NODE}, trying alternate BBS node")
            # Get the alternate node
            alt_node = [node for node in bbs_nodes if node != CURRENT_BBS_NODE][0]
            alt_url = f"{bbsurl}/raw-results/{alt_node}/buildsrc-summary.dcf"
            alt_r = requests.get(alt_url, timeout=10)
            
            if alt_r.status_code == 200:
                # Remember this successful node for future requests
                CURRENT_BBS_NODE = alt_node
                print(f"  Switching to {CURRENT_BBS_NODE} for BBS status checks")
                r = alt_r  # Use the successful response
            else:
                # Both nodes failed, use original response
                print(f"  Both BBS nodes failed for {pkg}")
                return "Not Found"
        
        # Continue with retries if needed
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

def load_bbs_cache(run_id):
    """Load BBS status cache to avoid repeated API calls"""
    cache_dir = f"runs/{run_id}/cache"
    bbs_cache_file = f"{cache_dir}/bbs_status.json"
    verified_bbs_file = f"{cache_dir}/verified_bbs.txt"
    
    bbs_cache = {}
    verified_bbs = set()
    
    os.makedirs(cache_dir, exist_ok=True)
    
    # Load BBS status cache
    if os.path.exists(bbs_cache_file):
        try:
            with open(bbs_cache_file) as f:
                bbs_cache = json.load(f)
        except:
            bbs_cache = {}
    
    # Load packages with verified BBS status
    if os.path.exists(verified_bbs_file):
        with open(verified_bbs_file) as f:
            verified_bbs = set(line.strip() for line in f if line.strip())
    
    return {"bbs_cache": bbs_cache, "verified_bbs": verified_bbs}

def save_bbs_cache(run_id, bbs_cache, verified_bbs):
    """Save BBS status cache and verified packages list"""
    cache_dir = f"runs/{run_id}/cache"
    bbs_cache_file = f"{cache_dir}/bbs_status.json"
    verified_bbs_file = f"{cache_dir}/verified_bbs.txt"
    
    os.makedirs(cache_dir, exist_ok=True)
    
    # Save BBS status cache
    with open(bbs_cache_file, 'w') as f:
        json.dump(bbs_cache, f)
    
    # Save verified BBS packages
    with open(verified_bbs_file, 'w') as f:
        for pkg in sorted(verified_bbs):
            f.write(f"{pkg}\n")

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
    
    # Load BBS status cache
    cache = load_bbs_cache(run_id)
    bbs_cache = cache["bbs_cache"]
    verified_bbs = cache["verified_bbs"]
    
    # Try to load previously used BBS node if available
    bbs_node_file = f"runs/{run_id}/cache/bbs_node.txt"
    if os.path.exists(bbs_node_file):
        with open(bbs_node_file, 'r') as f:
            node = f.read().strip()
            if node in ["nebbiolo1", "nebbiolo2"]:
                global CURRENT_BBS_NODE
                CURRENT_BBS_NODE = node
                print(f"Using previously successful BBS node: {CURRENT_BBS_NODE}")
    
    print(f"Found {len(packages)} total packages in Bioconductor {bioc_version}")
    print(f"Packages with verified BBS status: {len(verified_bbs)}")
    
    # Find all successful and failed packages directly from filesystem
    logs_dir = f"runs/{run_id}/logs"
    
    # Get successful packages by finding all build-success.log files
    successful = set()
    success_entries = []
    if os.path.exists(logs_dir):
        for pkg_dir in os.listdir(logs_dir):
            pkg_log_dir = os.path.join(logs_dir, pkg_dir)
            if os.path.isdir(pkg_log_dir) and os.path.exists(os.path.join(pkg_log_dir, "build-success.log")):
                successful.add(pkg_dir)
    
    # Get failed packages by finding all build-fail.log files
    failed = set()
    failed_entries = []
    if os.path.exists(logs_dir):
        for pkg_dir in os.listdir(logs_dir):
            pkg_log_dir = os.path.join(logs_dir, pkg_dir)
            if os.path.isdir(pkg_log_dir) and os.path.exists(os.path.join(pkg_log_dir, "build-fail.log")):
                failed.add(pkg_dir)
    
    # Process all packages with build status
    need_bbs_check = successful | failed
    print(f"Found {len(successful)} successful packages and {len(failed)} failed packages")
    print(f"Found {len(need_bbs_check)} packages needing BBS status check")
    
    # For each successful package, generate an entry
    for pkg in sorted(successful):
        pkg_url = f"https://bioconductor.org/packages/{bioc_version}/bioc/html/{pkg}.html"
        pkg_link = f"[{pkg}]({pkg_url})"
        log_path = f"runs/{run_id}/logs/{pkg}/build-success.log"
        log_link = f"[Log]({log_path})"
        
        # Check if we have a cached BBS status that's verified
        bbs = bbs_cache.get(pkg, "Not Found")
        if bbs == "Not Found" or pkg not in verified_bbs:
            print(f"Checking BBS status for {pkg}...")
            bbs = get_bbs_status(pkg, bioc_version)
            bbs_cache[pkg] = bbs
            if bbs != "Not Found":
                verified_bbs.add(pkg)
        
        success_entries.append([pkg_link, "Built", log_link, bbs])
    
    # For each failed package, generate an entry
    for pkg in sorted(failed):
        pkg_url = f"https://bioconductor.org/packages/{bioc_version}/bioc/html/{pkg}.html"
        pkg_link = f"[{pkg}]({pkg_url})"
        log_path = f"runs/{run_id}/logs/{pkg}/build-fail.log"
        log_link = f"[Log]({log_path})"
        
        # Check if we have a cached BBS status that's verified
        bbs = bbs_cache.get(pkg, "Not Found")
        if bbs == "Not Found" or pkg not in verified_bbs:
            print(f"Checking BBS status for {pkg}...")
            bbs = get_bbs_status(pkg, bioc_version)
            bbs_cache[pkg] = bbs
            if bbs != "Not Found":
                verified_bbs.add(pkg)
        
        # Analyze the failure reason
        with open(f"{logs_dir}/{pkg}/build-fail.log") as f:
            log_content = f.read()
        reasons = check_failure_reason(log_content)
        failed_entries.append([pkg_link, "Failed", log_link, bbs, "\n".join(reasons)])
    
    # Save updated BBS cache
    save_bbs_cache(run_id, bbs_cache, verified_bbs)
    
    # Save the current BBS node for future runs
    bbs_node_file = f"runs/{run_id}/cache/bbs_node.txt"
    with open(bbs_node_file, 'w') as f:
        f.write(CURRENT_BBS_NODE)
    print(f"Saved current BBS node ({CURRENT_BBS_NODE}) for future runs")
    
    # Build tables
    tables = {
        "succeeded": success_entries,
        "failed": failed_entries,
        "unprocessed": []
    }
    
    # Add remaining packages as unprocessed
    existing_pkgs = successful | failed
    
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
    print(f"- {len(verified_bbs)} packages have verified BBS status")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", help="Current run ID")
    args = parser.parse_args()
    main(args.run_id)
