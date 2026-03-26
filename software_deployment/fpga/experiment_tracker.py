import os
import yaml
from typing import Dict, List, Tuple, Optional
from tabulate import tabulate
import numpy as np
import pandas as pd

FPGA_FREQ = 100e6  # Hardware clock frequency in Hz (100 MHz)

class ExperimentTracker:
    """Tracks and reports statistics for SNN experiments."""
    
    def __init__(self):
        """Initialize the experiment tracker."""
        self.reset()
    
    def reset(self):
        """Reset all experiment statistics."""
        self.experiments = {}
        
    def add_experiment(self, dataset_name: str, network_name: str):
        """Add or reset an experiment entry.
        
        Args:
            dataset_name: Name of the dataset
            network_name: Name of the network
        """
        experiment_id = f"{dataset_name}/{network_name}"
        self.experiments[experiment_id] = {
            'dataset': dataset_name,
            'network': network_name,
            'weight_count': 0,
            'total_events': 0,
            'total_cycles': 0,
            'total_timesteps': 0,
            'correct_classifications': 0,
            'total_classifications': 0,
            'mse': 0.0,
            'mse_samples': 0
        }
        
    def update_experiment(self, dataset_name: str, network_name: str, 
                          weight_count: int = None,
                          events: int = None, 
                          cycles: int = None,
                          timesteps: int = None,
                          correct: int = None,
                          total: int = None,
                          mse: float = None,
                          mse_samples: int = None):
        """Update statistics for an experiment.
        
        Args:
            dataset_name: Name of the dataset
            network_name: Name of the network
            weight_count: Number of weights in the network
            events: Number of events processed
            cycles: Number of cycles spent processing
            timesteps: Number of timesteps processed
            correct: Number of correct classifications
            total: Total number of classifications
            mse: Mean Squared Error for this update
            mse_samples: Number of samples used in MSE calculation
        """
        experiment_id = f"{dataset_name}/{network_name}"
        
        # Create experiment if it doesn't exist
        if experiment_id not in self.experiments:
            self.add_experiment(dataset_name, network_name)
            
        # Update statistics
        if weight_count is not None:
            self.experiments[experiment_id]['weight_count'] = weight_count
        if events is not None:
            self.experiments[experiment_id]['total_events'] += events
        if cycles is not None:
            self.experiments[experiment_id]['total_cycles'] += cycles
        if timesteps is not None:
            self.experiments[experiment_id]['total_timesteps'] += timesteps
        if correct is not None:
            self.experiments[experiment_id]['correct_classifications'] += correct
        if total is not None:
            self.experiments[experiment_id]['total_classifications'] += total
        if mse is not None and mse_samples is not None and mse_samples > 0:
            # Update running MSE calculation
            current_mse = self.experiments[experiment_id]['mse']
            current_samples = self.experiments[experiment_id]['mse_samples']
            
            # Calculate weighted average of MSE values
            total_samples = current_samples + mse_samples
            if total_samples > 0:
                new_mse = (current_mse * current_samples + mse * mse_samples) / total_samples
                self.experiments[experiment_id]['mse'] = new_mse
                self.experiments[experiment_id]['mse_samples'] = total_samples
    
    def get_experiment(self, dataset_name: str, network_name: str) -> Optional[Dict]:
        """Get statistics for a specific experiment.

        Args:
            dataset_name: Name of the dataset
            network_name: Name of the network

        Returns:
            Dictionary containing experiment statistics, or None if no such experiment exists.
        """
        experiment_id = f"{dataset_name}/{network_name}"
        if experiment_id not in self.experiments:
            return None
        return self.experiments[experiment_id]
    
    def print_results(self):
        """Print a formatted table of experiment results."""
        if not self.experiments:
            print("No experiments have been conducted yet.")
            return
        
        # Prepare table data
        headers = ["Dataset", "Network", "Weights", "Events", "Timesteps", "Cycles", "Avg Latency (ms)", "Correct", "Total", "Accuracy (%)", "MSE"]
        rows = []
        
        for exp_id, stats in self.experiments.items():
            # Calculate accuracy
            accuracy = 0
            if stats['total_classifications'] > 0:
                accuracy = (stats['correct_classifications'] / stats['total_classifications']) * 100

            # Calculate average latency
            num_samples = stats['total_classifications']
            if num_samples > 0:
                avg_lat = stats['total_cycles'] / num_samples / FPGA_FREQ * 1e3
                avg_lat_str = f"{avg_lat:.3f}"
            else:
                avg_lat_str = "N/A"

            # Format row
            row = [
                stats['dataset'],
                stats['network'],
                f"{stats['weight_count']:,}",
                f"{stats['total_events']:,}",
                f"{stats['total_timesteps']:,}",
                f"{stats['total_cycles']:,}",
                avg_lat_str,
                stats['correct_classifications'],
                stats['total_classifications'],
                f"{accuracy:.2f}",
                f"{stats['mse']:.6f}" if stats['mse_samples'] > 0 else "N/A"
            ]
            rows.append(row)
        
        # Sort by dataset and network
        rows.sort(key=lambda x: (x[0], x[1]))
        
        # Print table
        print(tabulate(rows, headers=headers, tablefmt="grid"))
        
    def parse_samples_yaml(self, yaml_path: str) -> List[Tuple[str, int]]:
        """Parse a samples.yaml file to get sample files and their classes.
        
        Args:
            yaml_path: Path to the samples.yaml file
            
        Returns:
            List of tuples (sample_file_path, class_id)
        """
        if not os.path.exists(yaml_path):
            raise FileNotFoundError(f"Samples YAML file not found: {yaml_path}")
            
        try:
            with open(yaml_path, 'r') as file:
                samples_data = yaml.safe_load(file)
            
            samples = []
            base_dir = os.path.dirname(yaml_path)
            
            for sample_id, sample_info in samples_data.items():
                file_name = sample_info.get('file')
                class_id = sample_info.get('target')
                
                if file_name and class_id is not None:
                    file_path = os.path.join(base_dir, file_name)
                    samples.append((file_path, class_id))
                
            return samples
            
        except yaml.YAMLError:
            raise ValueError(f"Invalid YAML format in {yaml_path}")

    def export_all_to_csv(self, csv_path: str):
        """Export all experiments to a CSV file.
        
        Args:
            csv_path: Path to the CSV file
        """
        if not self.experiments:
            print("No experiments have been conducted yet.")
            return
        
        # Create a pandas DataFrame from the experiment data
        df = pd.DataFrame(self.experiments.values())
        
        # Rename columns for better readability
        df = df.rename(columns={
            'dataset': 'Dataset',
            'network': 'Network',
            'weight_count': 'Weights',
            'total_events': 'Events',
            'total_cycles': 'Cycles',
            'total_timesteps': 'Timesteps',
            'correct_classifications': 'Correct Classifications',
            'total_classifications': 'Total Classifications',
            'mse': 'Mean Squared Error',
            'mse_samples': 'MSE Samples'
        })
        
        # Calculate accuracy and add it to the DataFrame
        df['Accuracy (%)'] = (df['Correct Classifications'] / df['Total Classifications']) * 100
        
        # Export the DataFrame to a CSV file
        df.to_csv(csv_path, index=False)
        
        print(f"All experiments exported to {csv_path}")
