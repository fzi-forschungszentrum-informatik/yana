# YANA: A Framework for Event-Driven SNN Acceleration

YANA is an open-source, FPGA-based, event-driven digital spiking neural network (SNN) emulator designed to help close the simulation-to-hardware gap for neuromorphic computing. It processes spikes event-by-event and uses a near-memory, time-multiplexed neurosynaptic pipeline to support arbitrary, highly recurrent SNN graphs while exploiting both temporal and spatial sparsity for low-latency inference on platforms such as the AMD Kria KR260 and KV260.

To make the hardware broadly usable, YANA is accompanied by an end-to-end software framework that targets common neuromorphic workflows. It uses the [Neuromorphic Intermediate Representation (NIR)](https://github.com/neuromorphs/NIR) as an interchange format and is organized into three modules:

- **YANA train** — hardware-aware SNN training, using [Norse](https://github.com/norse/norse)
- **YANA deploy** — NIR parsing, fixed-point validation, and compilation into accelerator memory/routing configurations
- **YANA runtime** — PYNQ-based on-device control that loads configurations, streams events, runs inference, and reports performance metrics

At present, this repository hosts the sources to regenerate the KR260 YANA hardware prototype as used during [our tutorial at NICE 2025](https://flagship.kip.uni-heidelberg.de/jss/HBPm?mI=263&m=showAgenda&showAbstract=9849#9849) and our publication in Brain Informatics 2025. The software framework currently targets this hardware prototype.

---

## Table of Contents

- [Setup: Hardware](#setup-hardware)
  - [Requirements](#requirements)
  - [Recreate the YANA Prototype Vivado Project](#recreate-the-yana-prototype-vivado-project)
  - [Generate Bitstream and Export Hardware](#generate-bitstream-and-export-hardware)
  - [Using the YANA Prototype](#using-the-yana-prototype)
- [Setup: Kria Board OS and Software](#setup-kria-board-os-and-software)
  - [Requirements](#requirements-1)
  - [Creating the SD Card Image and Boot](#creating-the-sd-card-image-and-boot)
  - [Setting Up Dependencies](#setting-up-dependencies)
- [Setup: Host-side Software (SNN Training and Deployment Files)](#setup-host-side-software-snn-training-and-deployment-files)
  - [Requirements](#requirements-2)
  - [Setting up the virtual environment](#setting-up-the-virtual-environment)
  - [Using the software framework](#using-the-software-framework)
    - [Training](#training)
    - [Optimization through pruning](#optimization-through-pruning)
    - [Deployment](#deployment)
    - [Prepare and transfer files for FPGA experiments](#prepare-and-transfer-files-for-fpga-experiments)
- [Acknowledgments](#acknowledgments)
- [License](#license)
- [Citation](#citation)
- [Contact](#contact)

---

## Setup: Hardware

### Requirements

- Host with Linux, tested on Ubuntu 24.04 LTS
  - Windows can work, too — using our documented flow requires Linux due to use of .sh scripts
- Vivado 2024.1 (other versions may need adaptations to [./hardware_deployment/tcl/kr260_yana_prototype.tcl](hardware_deployment/tcl/kr260_yana_prototype.tcl))
- Know your Vivado installation path

### Recreate the YANA Prototype Vivado Project

Run the script [./hardware_deployment/recreate_project.sh](hardware_deployment/recreate_project.sh):

```bash
./hardware_deployment/recreate_project.sh -n kr260_yana_prototype -p "/PATH/TO/VIVADO/DIRECTORY" -v "2024.1" -t hardware_deployment/tcl/kr260_yana_prototype.tcl
```

- `-n` — name of the Vivado project
- `-p` — path to the directory that contains your Vivado installations (e.g. `/opt/Xilinx/Vivado/`)
- `-t` — path to the TCL script to use for the project
- `-v` — version of Vivado to use; the provided tcl script was generated using Vivado 2024.1

This creates a new Vivado project in `./hardware_deployment/projects/kr260_yana_prototype`.

### Generate Bitstream and Export Hardware

The regenerated Vivado project is ready to synthesize and implement without further modifications. Use Vivado GUI or tcl mode to generate the bitstream. The default target is the KR260, retarget to KV260 if needed. Once the bitstream is generated, export the hardware to an `.xsa` file, e.g. via tcl console:

```tcl
write_hw_platform -fixed -include_bit -force -file /PATH/TO/STORE/FILE.XSA
```

### Using the YANA Prototype

The prototype is used via a PYNQ-based Python API. Later you will upload the .xsa file to the board and use the Python API to run inference.
See [software_deployment/fpga/](../software_deployment/fpga/) for more details.

---

## Setup: Kria Board OS and Software

### Requirements

- AMD Kria KR260 or KV260 board 
- Host to prepare an SD card image
- Local network for your host and Kria board

### Creating the SD Card Image and Boot

- [Download the Ubuntu for Kria SD card image](https://ubuntu.com/download/amd#kria-k26)
  - Tested with Ubuntu Desktop 22.04
- Flash to SD card
- [Booting KR260](https://xilinx.github.io/kria-apps-docs/kr260/linux_boot/ubuntu_22_04/build/html/docs/intro.html) — [booting KV260](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/linux_boot/ubuntu_22_04/build/html/docs/intro.html)
- Add the board to your local network via ethernet
- Login via `ssh` (default username: `ubuntu`, password: `ubuntu`)
  - Tip: `sudo xmutil desktop_disable` to disable the desktop environment and gain some performance

### Setting Up Dependencies

- (all following while connected to the board via `ssh`)
- Install [Kria-PYNQ](https://github.com/Xilinx/Kria-PYNQ)
  - Tested commit `21bf5e1`
- JupyterLab can now be accessed via your host's web browser `<ip_address>:9090/lab`. Password is **xilinx**
- (all following with JupyterLab open)
- From the JupyterLab launcher, open a new terminal
  - `ctrl + shift + l` opens a new launcher, in case it vanished
- `cd ~/jupyter_notebooks && mkdir yana && chmod 777 yana`
- Copy the files in [software_deployment/fpga/](software_deployment/fpga/) and [tutorial/fpga/](tutorial/fpga/) to the `yana` directory
  - E.g. via JupyterLab file browser
- Locate the `.xsa` file that was exported from the Vivado project and copy it to the `yana` directory, too
- `cd yana` and `python3 -m pip install -r requirements.txt`

Following is the desired structure covered by the steps above:
```bash
root@kria:/root# tree
.
└── jupyter_notebooks
    └── yana
        ├── FPGA_notebook.ipynb
        ├── design_1_wrapper.xsa
        ├── experiment_tracker.py
        ├── experiments
        │   └── example
        │       ├── networks
        │       │   └── network_nmnist
        │       │       ├── [...]
        │       │       └── output_traces
        │       │           └── [...]
        │       └── test_samples
        │           └── [...]
        ├── experiments.zip
        ├── fixed_point.py
        └── yana_fpga.py

```

The board is now ready to evaluate experiments created via the YANA software framework. For this, proceed to the next section.

---

## Setup: Host-side Software (SNN Training and Deployment Files)

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

### Using the software framework
YANA's software framework is a toolkit that enables developers to train,
optimize, compile and deploy SNNs on the accelerator. To show an example
workflow of how its various tools can be used, multiple scripts are included.
This version of the software framework currently supports two different
event-based datasets: [N-MNIST](https://www.garrickorchard.com/datasets/n-mnist)
and [Spiking Heidelberg
Digits](https://zenkelab.org/resources/spiking-heidelberg-datasets-shd/).

Let's walk through how training, compiling and deploying a simple feed forward
SNN with one hidden layer looks like.

#### Training
The software framework uses a YAML-based configuration system. A configuration
file contains all information needed to describe the network architecture and
training setup. Each option present in the configuration file can be
overridden using the CLI. To show all available parameters, run:
```bash
# Navigate to software framework directory
cd software_framework
python3 accelerator_train.py -h
```
To start a training, select one of the two provided configurations. In this
example, we are using the SHD dataset:
```bash
# If you have a GPU
python3 accelerator_train.py -c yana/train/config/shd_feed_forward.yaml
# If you don't have a GPU (CPU training)
python3 accelerator_train.py -c yana/train/config/shd_feed_forward.yaml --trainer_cfg.device_num -1
```
You might want to consider limiting the amount of training epochs. By default, a
patience-based early stopping mechanism is used. To override the maximum number
of training epochs, run:
```bash
python3 accelerator_train.py -c yana/train/config/shd_feed_forward.yaml --trainer_cfg.num_epochs 10
```
The trained networks and their generated NIR files are placed into an output
folder. By default, this folder can be found at
`output/<dataset>/lightning_logs/version_xx`. In addition to that, an input
sample of the training dataset and the expected output of the network is
generated as stimulus and reference for the simulation later.

#### Optimization through pruning
Support for pruning is built into the software framework, as reducing the
network's active weights directly impacts the inference latency. To perform an
iterative pruning run with fine-tuning, you can load an existing checkpoint from
either the checkpoints directory or a previous training:
```bash
python3 accelerator_train.py \
  -c yana/train/config/shd_feed_forward.yaml \
  --trainer_cfg.checkpoint_path output/shd/lightning_logs/version_0/checkpoints/last.ckpt \
  --trainer_cfg.num_epochs 0 \
  --pruning_cfg.iterative_pruning true
```
This creates two new training directories:
`output/shd/lightning_logs/version_1`, which only contains the generated NIR
file and test stimuli of the selected checkpoint, and
`output/shd/lightning_logs/version_1_pruning`, which contains the trained
checkpoints and generated files of the pruning run.

#### Deployment
YANA's software framework contains a simulation of the fixed-point arithmetic
used inside the accelerator. To run the deployment, execute:
```bash
# Run deployment for unpruned network
python3 accelerator_deploy.py -i output/shd/lightning_logs/version_1
# Run deployment for pruned network
python3 accelerator_deploy.py -i output/shd/lightning_logs/version_1_pruning
```
This places the memory files required by the accelerator hardware inside
`output/shd/lightning_logs/<version>/deploy`. It also prints a utilization
report and the minimum squared error (MSE) between the PyTorch network and the
simulation.

> [!NOTE]
> The simulation is designed to be bit-accurate to the accelerator
> hardware. The PyTorch model also uses custom neuron models that mimic the
> quantization and fixed-point calculations in the hardware neuron. However, due
> to inconsistencies in rounding, the MSE can sometimes be >0. This however does
> not affect the performance of the network on hardware.

#### Prepare and transfer files for FPGA experiments
To evaluate the trained networks on the Xilinx Kria KV260 FPGA Board, we package
them into an experiment artifact directory alongside some input samples and
expected outputs:
```bash
python3 accelerator_export.py \
  --input-dirs output/shd/lightning_logs/version_1 \
               output/shd/lightning_logs/version_1_pruning \
  --num-samples 10
```
After this, an experiment archive file `output/experiments.tar.gz` will be
created.

This file needs to be transferred to the `~/jupyter_notebooks/yana/` directory
on the FPGA. The easiest way is through the JuypterLab GUI's upload
functionality (or drag and drop). In case you do not want to run you own
training and just want to see the accelerator in action, you can export the
provided pretrained networks (unpruned and 30% pruning for each dataset):
```bash
python3 accelerator_export.py --example
```
Once the experiment's archive has been uploaded to the FPGA, extract its contents
to make it runnable:
```bash
# Inside FPGA's terminal at ~/jupyter_notebooks/yana/
tar -xzf experiments.tar.gz -C experiments/
```

You are now ready to evaluate experiments created via the YANA software
framework. Via JupyterLab, you can open the `FPGA_notebook.ipynb` notebook and
follow its instructions to run the experiments and learn more about the
accelerator.

---

## Acknowledgments

Work on and with YANA was funded by the Federal Ministry of Research, Technology and Space (BMFTR, Germany) under grant numbers 16ME0517K, 16ME0564 and 16ME0818.

## License

- **Software** (in `software_deployment/`, `software_framework/` and `tutorial/`) is licensed under EUPL 1.2, see [LICENSE-software](LICENSE-software).
- **Hardware** (in `hardware_accelerator/rtl`) is licensed under CERN-OHL-W, see [LICENSE-hardware](LICENSE-hardware).
  - This project uses hardware design sources from the third party project [FPGADesignElements](https://github.com/laforest/FPGADesignElements), which is licensed by Charles Eric LaForest, PhD under MIT, see [LICENSE-elements](./hardware_accelerator/rtl/elements/LICENSE-elements).
- **Vivado Project Sources and IP:** The project configuration files (`.tcl`), block designs (`.bd`) and IP configuration files (`.xci`) located in `hardware_accelerator/block_design/`, `hardware_accelerator/ip/`, and `hardware_deployment/` represent the open-source configuration of this design and are licensed under CERN-OHL-W.
> [!WARNING]
> **Important Notice regarding Generated Artifacts:** The actual hardware description (HDL), netlists, design checkpoints, and bitstreams *generated* by AMD/Xilinx Vivado from these source files contain proprietary Intellectual Property owned by AMD/Xilinx. These generated output products are subject to the AMD/Xilinx End User License Agreement (EULA) and Core License Agreement. They are typically restricted to use on AMD/Xilinx devices and are **not** covered by the CERN-OHL-W license.

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
