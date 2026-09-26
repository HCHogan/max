module Max.Task.Policy (frontendToolLimit, frontendDeadlineSeconds, taskDeadlineSeconds, treeToolCalls, treeModelRounds) where

frontendToolLimit :: Int
frontendToolLimit = 600

frontendDeadlineSeconds :: Int
frontendDeadlineSeconds = 21600

-- Admission caps the whole task tree; descendants also inherit the parent's
-- remaining time. Leave room for slow local inference and transport retries.
taskDeadlineSeconds :: Int
taskDeadlineSeconds = 21600

-- Shared by every agent in one tree. Reaching either ends the tree's work
-- with a tool-free report, not a cancellation.
treeToolCalls :: Int
treeToolCalls = 2000

treeModelRounds :: Int
treeModelRounds = 2000
