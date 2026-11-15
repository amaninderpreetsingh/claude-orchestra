# Answers for /new-task --answers <this file>

Write the task in the command; this file answers the interview so the run needs no input.
Each question is a `## Q:` heading with its answer below it. Questions are matched by meaning,
so write them the way you expect to be asked. Anything not covered → the recommended option,
logged under Decisions. `approve: yes` approves the fast-path confirmation, the plan, every merge
that waits for your OK (risky tasks, `manual` merge policy) and the push.

approve: yes

## Q: Which filters should the list offer?
All, Active, Done — default All.

## Q: Should the chosen filter survive a reload?
Yes, keep it in localStorage.

## Q: Anything that must not change?
Existing add/complete/delete behaviour and the empty-state text.

## Q: How is "done" checked?
Playwright at 390px and desktop: each filter shows only its todos.
