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
  - Pipeline logs (downloaded locally).
  - Pipeline definition (YAML for YAML pipelines or JSON for classic pipelines).
  - Self-hosted agent details (if applicable).

**New Update:** The script now also generates a Markdown IcM report that summarizes the collected information in a human-readable format for quick escalation reference.

All information is compiled into a structured JSON report, and every action is logged to a timestamped log file.

## Prerequisites
- **Azure CLI**: Ensure the [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) is installed and available in your PATH.
- **Azure DevOps CLI Extension**: Install the extension:
  ```bash
  az extension add --name azure-devops
  ```
- **Azure Login**: Log in to Azure (`az login`) and ensure you have the necessary permissions.
- **PowerShell**: Requires PowerShell 5.x or higher.

## Usage

### Running the Script
You can run the script directly from a PowerShell console. The script accepts parameters to avoid interactive prompts. If parameters are not provided, the script will prompt for required values.

Example command:
```powershell
.\Collect-AdoPipelineEscTemplate.ps1 -Org "https://dev.azure.com/Contoso" -Project "ContosoProj" -PipelineIds 42,99 -IssueDescription "CI pipeline failing on npm install"
```

### Interactive Prompts
If parameters are omitted:
- **Org**: You will be prompted to enter your Azure DevOps Organization URL.
- **Project**: You will be prompted for the project name.
- **PipelineIds**: You will be prompted to enter one or more Pipeline IDs (comma-separated).
- **IssueDescription**: You will be prompted to provide a description of the issue.
- **Source Code Provider**: A menu will be displayed for provider selection if not auto-detected.

### Output
- **Logs**: A timestamped log file (e.g., `EscalationLog_20250409-1538.txt`) is saved in the output directory.
- **JSON Report**: A structured JSON report (e.g., `PipelineEscalationReport_20250409-1538.json`) is generated.
- **Markdown IcM Report (New)**: A Markdown report (e.g., `IcM_Report_20250409-1538.md`) is produced summarizing customer details, issue description, and key troubleshooting findings.
- **Other Artifacts**: Downloaded logs and pipeline definition files are stored in sub-folders.

## Script Workflow
1. **Azure Login**: Checks current Azure session and prompts for login if necessary.
2. **Prerequisite Check**: Verifies the presence of the Azure CLI and Azure DevOps extension.
3. **Data Collection**:
   - Gathers customer and issue details.
   - Retrieves pipeline run data (last successful run, first failing run, debug run).
   - Downloads logs and exports the pipeline definition.
   - (Optionally) Retrieves self-hosted agent details.
4. **Report Generation**:
   - Compiles all collected data into a JSON report.
   - **New:** Generates a Markdown IcM report using a predefined template.
5. **Logging**: Detailed logging is maintained in a timestamped log file for audit purposes.

## Extensibility
The script supports processing multiple pipelines and can be extended to include further diagnostics or integration with incident management systems.

## Important Notes
- **Sensitive Information**: Some logs or configuration details may contain sensitive data; handle output files securely.
- **Error Handling**: The script is fault-tolerant and logs errors without aborting the process.
- **Azure DevOps Authentication**: If your organization is not linked to your Azure login, consider using a Personal Access Token (PAT) with the necessary permissions.

---

By following the updated documentation and using the script, support engineers can now efficiently gather all relevant escalation data and receive both a detailed JSON report and a human-friendly Markdown IcM report, streamlining the incident escalation process.

**Sources:**

- Microsoft Docs – Troubleshoot pipeline runs and view logs  
- Azure CLI Documentation – for Azure DevOps commands  
- Stack Overflow – community solutions for pipeline log retrieval


