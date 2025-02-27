#!/usr/bin/env python3
import json
import argparse

def find_independent_packages(input_file, output_file, dispatched_file, successful_file):
    """
    Identify build-ready packages excluding dispatched and successful packages
    
    Args:
        input_file (str): Path to input JSON dependency file
        output_file (str): Path to write ready packages list
        dispatched_file (str): Path to dispatched packages list
        successful_file (str): Path to successful packages list
    """
    try:
        # Load dispatched packages (these stay in graph but can't be ready)
        dispatched = set()
        try:
            with open(dispatched_file, 'r') as f:
                dispatched.update(line.strip() for line in f if line.strip())
        except FileNotFoundError:
            print(f"Note: No dispatched packages file found at {dispatched_file}")

        # Load successful packages (these are removed from graph)
        successful = set()
        try:
            with open(successful_file, 'r') as f:
                successful.update(line.strip() for line in f if line.strip())
        except FileNotFoundError:
            print(f"Note: No successful packages file found at {successful_file}")

        # Load dependencies
        with open(input_file, 'r') as f:
            dependencies = json.load(f)

        # Remove successful packages from graph entirely
        filtered_deps = {
            pkg: [dep for dep in deps if dep not in successful]
            for pkg, deps in dependencies.items()
            if pkg not in successful
        }

        # Find ready packages (not dispatched, no remaining deps)
        independent = sorted([
            pkg for pkg, deps in filtered_deps.items()
            if not deps and pkg not in dispatched
        ])

        # Write output
        with open(output_file, 'w') as f:
            f.write('\n'.join(independent))
        
        print(f"Found {len(independent)} ready packages")
        print(f"Excluded {len(successful)} successful packages")
        print(f"Blocked {len(dispatched)} dispatched packages")

    except Exception as e:
        print(f"Error: {str(e)}")
        exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="BioConductor package build scheduler",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument('input_file', help='Path to JSON dependency file')
    parser.add_argument('output_file', help='Path to output ready packages list')
    parser.add_argument('dispatched_file', help='Path to dispatched packages list')
    parser.add_argument('successful_file', help='Path to successful packages list')
    
    args = parser.parse_args()
    
    find_independent_packages(
        args.input_file,
        args.output_file,
        args.dispatched_file,
        args.successful_file
    )
