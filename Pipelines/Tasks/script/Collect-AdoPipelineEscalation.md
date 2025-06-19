# Azure DevOps Pipeline Escalation Data Collection Script

## Overview
This PowerShell script automates the data collection process required for escalating Azure DevOps pipeline issues. It gathers essential information such as:

- **Customer Details**: Azure DevOps Organization URL, Project, Azure Subscription ID, AAD Tenant ID, and Source Code Provider.
- **Issue Details**: A free-form description of the issue.
- **Troubleshooting Information**:
  - Details from pipeline runs:
    - Last successful run.
    - First failing run.
    - Debug run (with `system.debug=true`) if available.
  - **Single-run logs ZIP** (`run{RunId}_logs.zip`) matching the portal download, for each selected run.
  - **Pipeline definitions** (YAML for YAML pipelines or JSON for classic pipelines).
  - Self-hosted agent details (if applicable).

**New Update:**  
- The script now packages **each run’s logs** into a single ZIP archive.  
- At the end of execution it **compresses the entire output directory** into `EscalationReport_{timestamp}.zip` for easy upload to your secure support workspace.  
- Generates a Markdown IcM report summarizing the collected information in human-readable form.

All information is compiled into a structured JSON report, and every action is logged to a timestamped log file.

---

## Prerequisites

- **Azure CLI**: Ensure the [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) is installed and available in your PATH.
- **Azure DevOps CLI Extension**:  
  ```powershell
  az extension add --name azure-devops
  ```

- **Azure Login**:

  ```powershell
  az login
  ```

  and ensure you have the necessary permissions.
* **PowerShell 5.x+** (for `Compress-Archive` support to bundle the final report).

---

## Usage

### Running the PowerShell Script

Before running the PowerShell script from this repository, you may need to update your PowerShell execution policy to allow script execution.

### Step 1: Open PowerShell as Administrator

Right-click on PowerShell and select **"Run as administrator."**

### Step 2: Set the Execution Policy

Run the following command to temporarily allow script execution for the current session:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
````

Alternatively, to set it for the current user permanently (if appropriate):

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

> ⚠️ Use `Bypass` or `Unrestricted` only if you understand the security implications.

### Running the Script

You can run the script directly from a PowerShell console. The script accepts parameters to avoid interactive prompts. If parameters are not provided, the script will prompt for required values.

```powershell
.\Collect-AdoPipelineEscalation.ps1 `
  -Org "https://dev.azure.com/Contoso" `
  -Project "ContosoProj" `
  -PipelineIds 42,99 `
  -OutputDir "C:\EscalationOutput"
```

### Interactive Prompts

If parameters are omitted:

* **Org**: Prompted for your Azure DevOps Organization URL.
* **Project**: A numbered list of projects in the org is presented for selection.
* **PipelineIds**: A numbered list of YAML & Classic pipelines (deduped) with their last run results; select one or more.
* **IssueDescription**: Prompted to provide a description of the issue.
* **Source Code Provider**: Menu-driven selection if not auto-detected.

### Output

* **Logs**:

  * For each selected run, downloads a portal-style ZIP (`run{RunId}_logs.zip`) containing **all** job and step logs.
* **Pipeline Definitions**:

  * YAML files (`*.yaml`) or JSON files (`*.json`) for each pipeline.
* **JSON Report**:

  * `PipelineEscalationReport_{timestamp}.json` — Structured data of everything collected.
* **Markdown IcM Report**:

  * `IcM_Report_{timestamp}.md` — Human-readable summary.
* **Full Report Package**:

  * `EscalationReport_{timestamp}.zip` — Bundles **all** above artifacts for easy upload to your secure workspace.

---

## Script Workflow

1. **Azure Login**

   * Ensures an interactive `az login` to acquire an AAD session.

2. **Prerequisite Check**

   * Verifies Azure CLI, Azure DevOps extension, and PowerShell version.

3. **Data Collection**

   * **Org & Project**: Reads or prompts for org URL and presents a project list.
   * **Pipeline Selection**: Lists YAML & Classic pipelines (deduped), annotated with last run status—select one or more.
   * **Pipeline Definitions**: Downloads YAML or exports Classic JSON definitions.
   * **Run Logs**: For each selected run, downloads a **single ZIP** of all logs (`$format=zip` endpoint).
   * **Agent Info**: (Optional) Gathers self-hosted agent details.

4. **Report Generation**

   * Compiles all collected data into a JSON report.
   * Generates a Markdown IcM report for quick human reference.

5. **Logging**

   * Maintains a detailed timestamped log file in the output directory.

6. **Packaging for Support**

   * Uses `Compress-Archive` to bundle the entire output folder into `EscalationReport_{timestamp}.zip`.
   * Logs instructions to upload this archive to your secure workspace for your Microsoft support case.

---

## Extensibility

The script supports multiple pipelines per run and can be extended to include:

* Additional diagnostics (e.g., environment variables, system info).
* Integration with incident management or ticketing systems via APIs.

---

## Important Notes

* **Sensitive Information**: Logs and definitions may expose secrets or environment details—handle the output securely.
* **Error Handling**: The script logs errors and continues wherever possible, ensuring maximum data collection.
* **Authentication**: Uses Azure AD tokens; no PAT required. Ensure your `az login` session has access to the DevOps org.

---

## Sources

* Microsoft Docs – [Troubleshoot pipeline runs and view logs](https://docs.microsoft.com/azure/devops/pipelines/troubleshooting)
* Azure CLI Documentation – for Azure DevOps commands
* Stack Overflow – community solutions for pipeline log retrieval
