---
name: mission
description: Perform a coding task such as implementing a feature or fixing a bug following a defined series of steps and best practices
---

# Mission Skill

## Critical Rules
1. **Stay in your work tree** - you can look at your `cwd` to know your current root; you should not need to read or modify files outside your current root
2. **Work in a branch** - you should perform your work in a branch. The correct naming convention is <agent-name>/<mission-name>. You should create a short name for your mission
3. **Write new tests** - if you implement new functionality you must write tests to prevent future regressions

## Workflow
The mission begins when a prompt provides detail on what needs to be accomplished.

1. Create your working branch, based off origin/main
2. Ask clarifying questions of the user to ensure the outcome is fully captured
3. Create a test plan with test cases and acceptance criteria
4. Proceed to implement the work, committing regularly with descriptive messages
5. Validate your work by running `npm run validate` to perform full E2E tests on the product
6. Fix any test failures and run again; repeat until all tests pass
7. Commit any remaining work and push your branch to remote
8. Create a PR using the gh CLI; provide rich description about the changes made and test cases as well as any manual validation needed for this work.
9. Once the PR is created, return to your standby branch and pull the latest from origin/main; await further instructions

**Clean State** - your standby state should be clean from untracked or uncommitted changes; if this is not the case let the user know before starting next work
