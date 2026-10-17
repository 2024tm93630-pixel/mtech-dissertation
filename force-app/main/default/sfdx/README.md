# AI-assisted Backlog Decision Framework — Salesforce source (Step 1)

Implements Project Blueprint v1.1: data model (Section 9) and the deterministic Scoring Engine (Section 7, Decisions #22-#30).

## Contents
- `force-app/main/default/objects/` — `Story__c`, `Gate_Result__c`, `Decision_Log__c` (35 fields)
- `force-app/main/default/classes/ScoringEngine.cls` — all Gate 1-3 states, flags, checklist scores, confidences, Gate 4 recommendation (no LLM, no SOQL/DML)
- `force-app/main/default/classes/ScoringEngineTest.cls` — 20 unit tests, runnable without any LLM
- `force-app/main/default/permissionsets/AI_Backlog_Framework_Admin` — object/field/class access

## Deploy (Salesforce CLI)
```
sf org login web --alias bdr-dev --set-default
sf project deploy start --source-dir force-app
sf org assign permset --name AI_Backlog_Framework_Admin
sf apex run test --class-names ScoringEngineTest --result-format human --code-coverage --wait 10
```
If you use VS Code: right-click `force-app` -> SFDX: Deploy Source to Org, then run the tests from the Apex Test panel.

## Data-model additions beyond Blueprint Section 9 (for the evaluation design)
| Field | Why |
|---|---|
| Story__c.Reference_Recommendation__c | Condition C: your manual judgment, recorded BEFORE running A/B |
| Story__c.Metadata_Tags__c / Similarity_Context__c | Static inputs Gate 2 needs (Decisions #6, #18) |
| Story__c.Test_Category__c | Which dataset case each story is (control, duplicate-pair, ...) |
| Gate_Result__c.Condition__c / Run_Number__c | A vs B and the 3 repeated runs for RQ1 variance |
| Gate_Result__c.Gate_Number__c = 0 | Convention for the Condition A single-prompt baseline |
| Gate_Result__c.Self_Reported_Confidence__c | LLM's own confidence for the RQ2 comparison |
| Gate_Result__c.Raw_Response__c, Model__c, Temperature__c, Prompt_Version__c, Latency_Ms__c | Audit + reproducibility |
| Gate_Result__c.Derived_Values__c | Apex-derived flags, override_fired, sub-reason (JSON) |
| Decision_Log__c.Overall_Confidence__c, Triggering_Rule__c | RQ2 correlation at decision time |

## Design note: exact thresholds
Overall_Confidence = (3*sum1 + 5*sum2 + 5*sum3) / 225, so the 0.75 and 0.5 cut-offs are compared as integers
(`Confidence.atLeast(num, den)`) — no floating-point ambiguity at the boundaries. The tests pin both sides of each boundary.

## Status
Not yet compiled or run in an org (no Salesforce CLI in the authoring environment). First action after deploying: run `ScoringEngineTest`.
