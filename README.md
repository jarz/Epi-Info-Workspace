# Epi Info workspace

This repository contains shared build and test tooling, an inventory, and a
modernization plan for six independent Epi Info repositories. It does not
contain or combine the product code; each product stays in its own repository.

## Set up a new workspace

Clone this repository and the product forks side by side in one parent
directory. The named branches contain the build and test changes described
here; Database Web has no corresponding changes and uses its default branch.

```powershell
Set-Location C:\ei
git clone https://github.com/jarz/Epi-Info-Workspace.git
git clone --branch copilot/build-and-test-baseline https://github.com/jarz/Epi-Info-Community-Edition.git
git clone --branch copilot/build-and-test-baseline https://github.com/jarz/Epi-Info-Web-Survey.git
git clone --branch copilot/build-and-test-baseline https://github.com/jarz/Epi-Info-Web-Enter.git
git clone --branch copilot/build-and-test-baseline https://github.com/jarz/Epi-Info-Survey-API.git
git clone --branch copilot/build-and-test-baseline https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing.git
git clone https://github.com/jarz/Epi-Info-Database-Web.git
```

```text
C:\ei\
  Epi-Info-Workspace\      this repository; scripts in eng\, local outputs in artifacts\ and scratch\
  Epi-Info-Community-Edition\
  Epi-Info-Web-Survey\
  ...
```

The scripts find the products in the workspace's parent directory; pass `-Root`
to use another location. Local outputs (`artifacts\`, `scratch\`) are ignored.

- [Build instructions and selected test baselines](BUILDING.md)
- [Repository and dependency inventory](INVENTORY.md)
- [Modernization plan](MODERNIZATION.md)
- [Prioritized project updates and Cloud deployment evidence](PRIORITIES.md)

Builds do not establish deployment or service compatibility.
