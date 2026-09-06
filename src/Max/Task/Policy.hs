module Max.Task.Policy (frontendToolLimit, frontendDeadlineSeconds, frontendLeaseSeconds, taskDeadlineSeconds) where

frontendToolLimit :: Int
frontendToolLimit = 600

frontendDeadlineSeconds :: Int
frontendDeadlineSeconds = 21600

-- Leave time for the terminal checkpoint after the foreground deadline.
frontendLeaseSeconds :: Int
frontendLeaseSeconds = frontendDeadlineSeconds + 150

-- Admission caps the whole task tree; descendants also inherit the parent's
-- remaining time. Leave room for slow local inference and transport retries.
taskDeadlineSeconds :: Int
taskDeadlineSeconds = 21600
