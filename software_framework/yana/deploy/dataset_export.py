# ******************************************************************************************
# All Rights Reserved
#
# Copyright (c) 2021-2025 FZI Forschungszentrum Informatik
#
# THE CONTENTS OF THIS SOFTWARE ARE PROPRIETARY AND CONFIDENTIAL.
#
# UNAUTHORIZED COPYING, TRANSFERRING OR REPRODUCTION OF THE CONTENTS OF THIS SOFTWARE, VIA
# ANY MEDIUM IS STRICTLY PROHIBITED.
#
# The software is provided "AS IS", without warranty of any kind, express or implied,
# including but not limited to the warranties of merchantability, fitness for a particular
# purpose and non-infringement.
#
# In no event shall the authors or copyright holders be liable for any claim, damages or
# other liability, whether in an action of contract, tort or otherwise, arising from, out
# of or in connection with the software or the use or other dealings in the software.
#
# The licensor shall never, and without any limit, be liable for any damage, cost, expense
# or any other payment incurred by the licensee as a result of the software's actions,
# failure, bugs and/or any other interaction between the software and the licensee's
# end-equipment, computers, other software or any 3rd party, end-equipment, computer or
# services.
# ******************************************************************************************

import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import torch
import yaml


def allocate_run_dir(
    deploy_root: str, dataset_name: str, experiment_name: Optional[str] = None
) -> Path:
    """Allocate an export run directory under deploy_root.

    By default creates ``{dataset}_{N}/init/`` and ``{dataset}_{N}/dataset/``
    where *N* is the next free integer suffix (0, 1, 2, …). If *experiment_name*
    is given, that exact name is used instead and no integer suffix is appended.
    """
    os.makedirs(deploy_root, exist_ok=True)

    if experiment_name is not None:
        run_dir = Path(deploy_root) / experiment_name
    else:
        base = dataset_name.lower()
        pattern = re.compile(rf"^{re.escape(base)}_(\d+)$")

        max_idx = -1
        for entry in os.listdir(deploy_root):
            if not os.path.isdir(os.path.join(deploy_root, entry)):
                continue
            match = pattern.match(entry)
            if match:
                max_idx = max(max_idx, int(match.group(1)))

        run_dir = Path(deploy_root) / f"{base}_{max_idx + 1}"

    (run_dir / "init").mkdir(parents=True, exist_ok=True)
    (run_dir / "dataset").mkdir(parents=True, exist_ok=True)
    return run_dir


def collect_train_samples(
    trainset, num_samples: int, seed: int,
) -> List[Tuple[np.ndarray, int]]:
    """Pick a random subset from the training set, loading one sample at a time.

    Returns a list of ``(sequence, target)`` pairs where *sequence* has shape
    ``[T, ...]`` and *target* is the integer class label.
    """
    total = len(trainset)
    num_samples = min(num_samples, total)

    generator = torch.Generator().manual_seed(seed)
    indices = torch.randperm(total, generator=generator)[:num_samples].tolist()

    samples: List[Tuple[np.ndarray, int]] = []
    for idx in indices:
        data, target = trainset[idx]
        if torch.is_tensor(data):
            data = data.numpy()
        if torch.is_tensor(target):
            target = target.item()
        samples.append((data, int(target)))

    return samples


def write_sample_info(dataset_dir: str, samples_meta: List[Dict[str, Any]]) -> None:
    """Write sample_info.yaml keyed by sample index."""
    info = {idx: meta for idx, meta in enumerate(samples_meta)}
    info_path = os.path.join(dataset_dir, "sample_info.yaml")
    with open(info_path, "w") as f:
        yaml.safe_dump(info, f, sort_keys=False)
