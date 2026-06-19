from typing import List, Optional

import numpy as np


class IncrementalPruningScheduler:
    """Simple incremental pruning schedule.

    Starting from ``increment`` sparsity, the target sparsity is raised by
    ``increment`` every ``frequency`` epochs until ``target_sparsity`` is
    reached.  The model is fine-tuned for ``frequency`` epochs between
    successive pruning steps.
    """

    def __init__(self,
                 target_sparsity: float,
                 increment: float,
                 frequency: int,
                 start_epoch: int = 0):
        if not 0.0 < target_sparsity < 1.0:
            raise ValueError(f"target_sparsity must be in (0, 1), got {target_sparsity}")
        if not 0.0 < increment <= target_sparsity:
            raise ValueError(f"increment must be in (0, target_sparsity], got {increment}")
        if frequency < 1:
            raise ValueError(f"frequency must be >= 1, got {frequency}")

        self.target_sparsity = target_sparsity
        self.increment = increment
        self.frequency = frequency
        self.start_epoch = start_epoch

        # Build the list of target sparsities for each pruning step.
        sparsities = [round(float(s), 10) for s in np.arange(increment, target_sparsity, increment)]
        if not sparsities or abs(sparsities[-1] - target_sparsity) > 1e-9:
            sparsities.append(float(target_sparsity))
        self.target_sparsities: List[float] = sparsities

        # The epoch at which each pruning step is applied.
        self._pruning_epochs = [
            start_epoch + i * frequency for i in range(len(self.target_sparsities))
        ]

    def check_pruning_step(self, current_epoch: int) -> Optional[float]:
        """Return the target sparsity if ``current_epoch`` is a pruning step, else None."""
        if current_epoch in self._pruning_epochs:
            return self.target_sparsities[self._pruning_epochs.index(current_epoch)]
        return None

    def total_epochs(self) -> int:
        """Total number of epochs needed to run the full schedule."""
        return self.start_epoch + self.frequency * len(self.target_sparsities)

    def print_schedule(self):
        print("Pruning Schedule (simple, incremental):")
        print("-" * 50)
        for epoch, target in zip(self._pruning_epochs, self.target_sparsities):
            end_epoch = epoch + self.frequency - 1
            print(f"Epoch {epoch:3d}: Prune to {target:5.1%} sparsity")
            print(f"          Fine-tune for {self.frequency} epochs (until epoch {end_epoch})")
        print("-" * 50)
        print(f"Total pruning duration: {self.total_epochs()} epochs")
        print(f"Final target sparsity: {self.target_sparsities[-1]:5.1%}")
