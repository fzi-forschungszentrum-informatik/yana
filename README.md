# YANA: A Framework for Event-Driven SNN Acceleration

YANA is an open-source, FPGA-based, event-driven digital spiking neural network (SNN) emulator designed to help close the simulation-to-hardware gap for neuromorphic computing. It processes spikes event-by-event and uses a near-memory, time-multiplexed neurosynaptic pipeline to support arbitrary, highly recurrent SNN graphs while exploiting both temporal and spatial sparsity for low-latency inference on platforms such as the AMD Kria KR260 and KV260.

To make the hardware broadly usable, YANA is accompanied by an end-to-end software framework that targets common neuromorphic workflows. It uses the [Neuromorphic Intermediate Representation (NIR)](https://github.com/neuromorphs/NIR) as an interchange format and is organized into three modules:

- [**YANA core**](software_framework/yana/core/) — Basic hardware configuration and fixed-point arithmetic
- [**YANA train**](software_framework/yana/train/) — hardware-aware SNN training, using [Norse](https://github.com/norse/norse)
- [**YANA deploy**](software_framework/yana/deploy/) — NIR parsing, fixed-point validation, and compilation into accelerator memory/routing configurations

This repository hosts the RTL sources and software framework for YANA, enabling the training, deployment and simulation of the accelerator hardware using a fully open-source toolchain.

YANA has been shown in multiple tutorials and publications:
- [Tutorial at NICE 2025](https://flagship.kip.uni-heidelberg.de/jss/HBPm?mI=263&m=showAgenda&showAbstract=9849#9849)
- Publication in Brain Informatics 2025 ([arxiv](https://arxiv.org/abs/2604.03432))
- [Tutorial at HEART 2026](https://heart2026.github.io/Tutorial.html)

## Table of Contents

- [Quick start using Docker (recommended)](#quick-start-using-docker-recommended)
- [Manual setup](#manual-setup)
  - [Requirements](#requirements)
  - [Setting up the virtual environment](#setting-up-the-virtual-environment)
  - [Prerequisites for Verilog simulation](#prerequisites-for-verilog-simulation)
- [Using YANA - Software Toolchain](#using-yana---software-toolchain)
  - [Train your own networks](#train-your-own-networks)
  - [Optimization through pruning](#optimization-through-pruning)
  - [Deploy your self-trained networks](#deploy-your-self-trained-networks)
  - [Deploy pre-trained networks](#deploy-pre-trained-networks)
- [Using YANA - RTL Simulation](#using-yana---rtl-simulation)
- [Customization](#customization)
  - [Use other datasets](#use-other-datasets)
  - [Change the network configuration](#change-the-network-configuration)
  - [Change the training parameters](#change-the-training-parameters)
- [Acknowledgments](#acknowledgments)
- [License](#license)
- [Citation](#citation)
- [Contact](#contact)

## Quick start using Docker (recommended)
To quickly get YANA up and running, use the docker image provided which includes
the necessary Python environment for the software framework as well as
[Verilator](https://verilator.org/guide/latest/) for running RTL simulations.

To create a docker container using the image, simply run
```bash
cd docker
./up.sh
```
which will create a new container, mount this directory into `/workspace` and
duplicate your user in the container (to avoid permission conflicts for files
created inside the container).

If you prefer running the container manually, simply pull and run the container
like follows:
```bash
docker pull ghcr.io/neher-fzi/yana:latest
docker run -it --rm -v `pwd`:/workspace ghcr.io/neher-fzi/yana:latest
```

## Manual setup

### Requirements
- Python 3.10 or later installed on the system
- Virtual environment support (obtainable via `sudo apt install python3-venv`)

### Setting up the virtual environment
YANA's software framework is a self-contained Python module. To install it and
its dependencies, you simply need to create a virtual environment and install it
using pip:

1. Create new virtual environment
```bash
# Create and activate virtual environment
python3 -m venv .venv
source .venv/bin/activate
```
2. Install the YANA software framework and its requirements
```bash
pip install -e ./software_framework
```
3. If everything is set up correctly, you should be able to execute the
   following command:
```bash
python3 -m yana --version
```

### Prerequisites for Verilog simulation
We use [Verilator](https://verilator.org/guide/latest/) for RTL simulation of
the hardware design. Refer to their documentation for instructions on how to set
it up for your system.

## Using YANA - Software Toolchain
YANA's software framework is a toolkit that enables developers to train,
optimize, compile and deploy SNNs on the accelerator. To show an example
workflow of how its various tools can be used, multiple scripts are included.
This version of the software framework currently supports two different
event-based datasets: [N-MNIST](https://www.garrickorchard.com/datasets/n-mnist)
and [Spiking Heidelberg
Digits](https://zenkelab.org/resources/spiking-heidelberg-datasets-shd/).

Let's walk through how training, deploying and running a simple feed forward SNN
with one hidden layer looks like. The following steps assume you are using the
[Docker setup](#quick-start-using-docker-recommended).

### Train your own networks
The software framework uses a YAML-based configuration system. A configuration
file contains all information needed to describe the network architecture and
training setup. Almost all options in the configuration file can be
overridden using the CLI. To show all available parameters, run:
```bash
# Navigate to software framework directory
cd software_framework
python3 train_network.py -h
```
To start a training, select one of the two provided configurations. In this
example, we are using the SHD dataset (as is it smaller and downloads quicker):
```bash
python3 train_network.py -c yana/train/config/shd_feed_forward.yaml \
    --trainer_cfg.num_epochs 20
```
By default, a patience-based early stopping mechanism is used. We override it to
a maximum of 20 epochs in the interest of time. The checkpoints and
configuration files for the trained networks are placed into an output folder.
This folder can be found at `output/<dataset>/lightning_logs/version_x`.

The training will take a while, so to kill the time use
```bash
tensorboard --logdir /workspace/software_framework/output/shd/lightning_logs \
    --bind_all
```
to monitor the progress of you training. In VS Code, just click the displayed
link. If you are using a terminal or another editor that doesn't automatically
forward ports, use [http://172.17.0.2:6006](http://172.17.0.2:6006) (or the IP
adress of your Docker container, if you have multiple running).

### Optimization through pruning
Support for pruning is built into the software framework, as reducing the
network's active weights directly impacts the inference latency on YANA thanks
to its fully event-driven architecture. To perform an iterative pruning run with
fine-tuning, you can load the checkpoint of the network you trained earlier:
```bash
python3 prune_network.py -C output/shd/feed_forward/lightning_logs/version_0
```
Which creates a new directory
`output/shd/feed_forward/lightning_logs/version_0_pruning`. For each stage of
the iterative fine-tuned pruning the best checkpoint is stored.

### Deploy your self-trained networks
YANA's [`deploy`](software_framework/yana/deploy/) module contains a bit-accurate emulation of the fixed-point
arithmetic used inside the accelerator. It also generates all required weight
and routing memory entries to initialize the hardware. To deploy your trained
networks, run
```bash
python3 deploy_checkpoint.py \
    -C output/shd/feed_forward/lightning_logs/version_0/ \
    -o ../hardware_accelerator/sim/tb_yana_top/files/ \
    -e custom_trained -n 10
```

### Deploy pre-trained networks
For convenience we include a few pretrained networks in the
[`software_framework/pretrained`](software_framework/pretrained/) directory. Let us run the deployment for a few
of them:
```bash
# Simple single layer network
python3 deploy_checkpoint.py -C pretrained/shd/ -o \
    ../hardware_accelerator/sim/tb_yana_top/files/ \
    -e shd_unpruned -n 10
# Single layer network (pruned to 60% sparsity)
python3 deploy_checkpoint.py -C pretrained/shd_pruning/ -o \
    ../hardware_accelerator/sim/tb_yana_top/files/ \
    -e shd_pruned_60 -n 10
# Two layer network
python3 deploy_checkpoint.py -C pretrained/shd_two_layer/ -o \
    ../hardware_accelerator/sim/tb_yana_top/files/ \
    -e shd_two_layer -n 10
```
Note that the two layer network occopies both available hidden cores of our 2x2
multi-core setup. In the current version, layers get distributed to cores using
a round-robin assignment (as shown by the output).

## Using YANA - RTL Simulation
To actually see YANA in action, we use Verilator to simulate the initialiazation
and inference of SNNs. The testbench and `make` setup for the simulation can be
found in the [`hardware_accelerator/sim/tb_yana_top`](hardware_accelerator/sim/tb_yana_top/) directory. To run the
simulation using the example network (without running any training or
deployment), execute
```bash
# Inside hardware_accelerator/sim/tb_yana_top
make run-fast
```
Verilator supports waveform outputs readable by waveform viewers like
[GtkWave](https://github.com/gtkwave/gtkwave) or
[Surfer](https://surfer-project.org/). To output waveform `.fst` files, run
```bash
make run-trace
```
which outputs a `waveform.fst` file in the simulation directory.

Let's compare the inference of multiple networks with each other, namely the
pretrained networks deployed in the [previous
section](#deploy-pre-trained-networks):
```bash
DATASETS=shd_unpruned,shd_pruned_60,shd_two_layer NUM_SAMPLES=10 make run-fast
```
The summary shows that the pruned network effectively scales linearly in latency
with the pruning ratio. Also, the two layer network takes the same amount of
time as the single layer network, because each layer is processed concurrently
on different cores.

## Customization

### Use other datasets
- Use the N-MNIST dataset by selecting the [N-MNIST config file](software_framework/yana/train/config/nmnist_feed_forward.yaml):
  ```bash
  python3 train_network.py -c yana/train/config/nmnist_feed_forward.yaml
  ```

### Change the network configuration
- More or less neurons per layer — set [`out_features`](software_framework/yana/train/config/shd_feed_forward.yaml#L37) in the hidden `Linear` layer of the config file
- Other neuron parameters — modify [`tau_inv_mem`, `threshold`, and `neuron_type`](software_framework/yana/train/config/shd_feed_forward.yaml#L39-L43) in the `create_hidden_cell` block of the config file
  - **NOTE:** all neurons mapped on the hidden layer must have the same neuron parameters (`tau`, `threshold`, `neuron_type`)

### Change the training parameters
- Different optimizer — change [`optimizer`](software_framework/yana/train/config/shd_feed_forward.yaml#L64) in `optimizer_cfg` of the config file (alternatives: `AdamW`, `RMSprop`, `SGD`)
- Other learning rate scheduler — change [`lr_scheduler` and `lr_scheduler_cfg`](software_framework/yana/train/config/shd_feed_forward.yaml#L67-L72) in the config file, or implement a custom one in [lr_scheduler.py](software_framework/yana/train/model/lr_scheduler.py)

## Acknowledgments

Work on and with YANA was funded by the Federal Ministry of Research, Technology and Space (BMFTR, Germany) under grant numbers 16ME0517K, 16ME0564 and 16ME0818.

## License

- **Software** (in [`software_framework/`](software_framework/)) is licensed under EUPL 1.2, see [LICENSE-software](LICENSE-software).
- **Hardware** (in [`hardware_accelerator/`](hardware_accelerator/)) is licensed under CERN-OHL-W, see [LICENSE-hardware](LICENSE-hardware).
  - Portions of the hardware RTL are derived from third-party MIT-licensed projects: [FPGADesignElements](https://github.com/laforest/FPGADesignElements) ([LICENSE-elements](./hardware_accelerator/rtl/elements/LICENSE-elements)) and [RANC](https://github.com/UA-RCL/RANC) ([LICENSE-ranc](./hardware_accelerator/rtl/noc/LICENSE-ranc)).

## Citation

If you use YANA in your research, please cite our paper:

```bibtex
@article{yana_brain_informatics_2025,
  title={YANA: Bridging the Neuromorphic Simulation-to-Hardware Gap},
  author={Pachideh, Brian and Nitzsche, Sven and Neher, Moritz and Krausse, Jann and Weigelt, Carmen and Knobloch, Klaus and Pazmino Betancourt, Victor and Becker, Juergen},
  booktitle={International Conference on Brain Informatics},
  year={2025},
  organization={Springer}
}
```

## Contact

[Brian Pachideh](mailto:pachideh@fzi.de) — Cc: [Moritz Neher](mailto:neher@fzi.de), [Sven Nitzsche](mailto:nitzsche@fzi.de)
