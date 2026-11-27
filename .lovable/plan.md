# Simple Team Task & Daily Report System

## Goal
Replace the blank starter page with a clear, practical team workspace based on the uploaded brief.

## First version
- Sign in as an Admin or Team Member. Store each person’s name and department.
- Admins can add team members, assign tasks, and see a simple team overview.
- Team Members see only their own tasks, update task status, and submit one daily report with completed work, work in progress, blockers, and tomorrow’s plan.
- Members can review their own past reports. Reports and tasks stay private to their owner; Admins can see the full team.
- Keep the navigation short and the labels plain, with a focused dashboard for each role.

## Keep it simple
Defer Google Sheets syncing, item-by-item sharing, extensive activity logs, and advanced reporting. These can be added later without changing the core task and report workflow.

## Technical details
- Enable Lovable Cloud for sign-in and saved data.
- Keep Admin and Team Member permissions enforced by the data layer, not just by hiding screens. Store roles separately from profile details.
- Add focused checks for private access, task ownership, and one report per person per day.
- Give each page its own clear title and description.
