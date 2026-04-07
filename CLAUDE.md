# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Salesforce DX - Employee Onboarding Tracker

**Org Alias**: `pre-release-org` | **API Version**: 65.0 | **Namespace**: (empty)

## Critical Commands

```bash
sf project deploy start --target-org pre-release-org
sf project deploy validate --target-org pre-release-org
sf project retrieve start --target-org pre-release-org
sf org open --target-org pre-release-org
sf apex run --file temp.apex --target-org pre-release-org
sf apex run test --code-coverage --result-format human --target-org pre-release-org
sf apex run test --class-names OnboardingServiceTest --target-org pre-release-org
npm run test:unit
npm run test:unit -- --watch
npm run lint
```

Conflict resolution: retrieve first, merge manually, then deploy.

## Architecture Overview

### Domain
Employee Onboarding Tracker. Core objects:
- `Onboarding_Request__c` — the root entity per new hire (Status, Completion_Percentage__c, Start_Date__c, Department__c, etc.)
- `Onboarding_Task__c` — child tasks per request; completion drives the parent's `Completion_Percentage__c`
- `Onboarding_Comment__c` — notes/comments on requests
- `Employee__c` — created upon request completion
- `Onboarding_Task_Template__mdt` — custom metadata defining default tasks (IT, Facilities, HR, Training)

### Apex Layer
Trigger → Handler → Service architecture. One trigger per object, logic-less:

```
OnboardingRequestTrigger  →  OnboardingRequestTriggerHandler  →  OnboardingService
OnboardingTaskTrigger     →  OnboardingTaskTriggerHandler      →  OnboardingService
```

`OnboardingService` is the core class (~1000 lines). It contains all business logic: task auto-creation from templates, completion percentage calculation, validation, `@AuraEnabled` methods for LWC, and reminder email helpers.

Async processing:
- `OnboardingReminderScheduler` — scheduled daily at 8 AM, enqueues the batch
- `OnboardingReminderBatch` — batch size 50, sends reminder emails for requests starting within 3 days

### LWC Components
| Component | Purpose |
|-----------|---------|
| `onboardingDashboard` | Main dashboard; filtering by Department/Status/Location/Work Mode, kanban expansion, task completion |
| `onboardingRequestForm` | Create new onboarding requests |
| `onboardingKanbanBoard` | Kanban board view by status |
| `onboardingComments` | Comments/notes on a request |

LWCs use `@wire` + `refreshApex`, `NavigationMixin`, and `ShowToastEvent`. Wire adapter methods live in `OnboardingService`.

### Flows
All flows are screen or invocable flows (no record-triggered flows exist):
- `New_Hire_Onboarding_Wizard` — guided screen flow for new hires
- `Onboarding_Request_Approval_Process` — orchestrated approval routing to HR_Approvals group
- `Submit_Onboarding_Request_for_Approval` — routes request to approval
- `Update_the_Onboarding_Request_Status` — status updates
- `Onboarding_Completion_Notification` — completion notifications

## Development Rules

### Trigger Pattern
One trigger per object → Handler → Service. Handlers route events via switch statement; zero logic in triggers or handlers beyond routing.

### Builder Pattern
**All classes with DML must use the Builder Pattern:**
```apex
new OnboardingRequestBuilder().withEmployeeName('Jane').withDepartment('IT').buildAndInsert();
new OnboardingTaskBuilder().withName('Setup Laptop').withRequestId(reqId).build();
```
Methods: `withFieldName()` for each field, `build()` returns the SObject, `buildAndInsert()` builds and inserts.

### Security
- Every Apex class must declare `with sharing`, `without sharing`, or `inherited sharing`.
- DML: use `insert as user` / `update as system` explicitly.
- SOQL: use `with user_mode` or `with system_mode` explicitly.

### Governor Limits
No DML or SOQL inside loops. Use collections/maps. Batch Apex for operations that may exceed email or query limits.

### Bypass Logic
Every record-triggered Flow must include a Bypass check via Custom Permission or Hierarchy Setting.

### Naming Conventions
- Apex: `PascalCase` classes, `camelCase` methods
- LWC: `kebab-case` folders, `camelCase` JS properties
- Flows: label format `"Object Action: Trigger"` (e.g., `"Onboarding Request: After Create"`)

## Testing Standards
- Use `TestDataFactory` for all test record creation; never `(seeAllData=true)`.
- Every test must have at least one `Assert.areEqual()` or equivalent assertion.
- Target >85% coverage. Existing test classes: `OnboardingServiceTest`, `OnboardingTriggerHandlerTest`, `OnboardingReminderBatchTest`.

## Deployment Notes
- `sourceApiVersion` is 65.0; org runs on API 66.0 — keep source at 65.0.
- Circular dependency pattern: deploy objects/classes/LWC first, then flows that reference them.
- `rollbackOnError=true` causes full rollback on any single failure — use two-stage deploy when needed.
