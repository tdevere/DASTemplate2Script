# README

Welcome to the **GitHub + Azure Boards** integration workflow! This guide will help new contributors link their code changes to Azure DevOps work items and track progress seamlessly.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Workflow Overview](#workflow-overview)
3. [Detailed Steps](#detailed-steps)

   * [1. Identify Your Work Item](#1-identify-your-work-item)
   * [2. Create a Feature Branch](#2-create-a-feature-branch)
   * [3. Link Commits to the Work Item](#3-link-commits-to-the-work-item)
   * [4. Push and Open a Pull Request](#4-push-and-open-a-pull-request)
   * [5. Track Progress in Azure Boards](#5-track-progress-in-azure-boards)
4. [Optional: Create Branch from Azure Boards](#optional-create-branch-from-azure-boards)
5. [Best Practices](#best-practices)
6. [Help & Resources](#help--resources)

---

## Prerequisites

Before you begin, ensure you have:

* Git installed on your local machine.
* Read/write access to this GitHub repository.
* The **Azure Boards** GitHub App installed and connected to this repository (configured under **Project Settings → GitHub connections** in Azure DevOps).

---

## Workflow Overview

This workflow will guide you through:

1. Creating a branch named after your Azure Boards work item.
2. Linking commits and pull requests to that work item using `AB#<id>` syntax.
3. Tracking development progress directly from your work item in Azure Boards.

---

## Detailed Steps

### 1. Identify Your Work Item

1. Open [Azure Boards](https://dev.azure.com) and navigate to your project.
2. Find the work item you will implement and note its **ID** (e.g., `123`).

### 2. Create a Feature Branch

On your local machine, in the root of this repo, run:

```bash
git fetch
# Use kebab-case for descriptions
git checkout -b feature/123-short-description
```

* Replace `123` with your work item ID.
* Use a concise, lowercased description (e.g., `feature/123-add-login-form`).

### 3. Link Commits to the Work Item

When committing your changes, reference your work item in each message:

```bash
git add .
git commit -m "AB#123: Implement user login form and validation"
```

* The `AB#123` token links this commit to work item **123**.

### 4. Push and Open a Pull Request

Push your branch and open a PR on GitHub:

```bash
git push -u origin feature/123-short-description
```

* In the PR title or description, include `AB#123` (e.g., `AB#123: Add login form`).
* Using keywords like `Fixes AB#123` will automatically transition the work item to **Done** when the PR is merged.

### 5. Track Progress in Azure Boards

* In Azure Boards, open work item **123**.
* Under the **Development** section, you’ll see linked branches, commits, and pull requests.
* Merge your PR and watch the work item update automatically.

---

## Optional: Create Branch from Azure Boards

If you prefer one-click branch creation:

1. In Azure Boards, open your work item.
2. In the **Development** panel, click **Create branch**.
3. Select this GitHub repo and click **Create**.
4. Locally, run:

   ```bash
   git fetch
   ```

git checkout feature/123-auto-generated-description

```

This pre-fills the correct branch name and links it automatically.


---

## Best Practices

- **Branch naming:** Always start with `feature/` followed by `<work-item-id>-<short-description>`.
- **Commit messages:** Begin with `AB#<id>:` to ensure linkage.
- **Pull requests:** Use consistent templates that remind you to reference work items.
- **Branch policies:** Ensure that PRs require a linked work item before merging.


---

## Help & Resources

- [Azure Boards documentation](https://docs.microsoft.com/azure/devops/boards/)
- Contact the DevOps team if you encounter any issues.

---

Happy coding! 🎉
