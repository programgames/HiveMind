-- HiveMind job queue
--
-- A breeding campaign runs for hours of game time across eight machines. The
-- computer will be stopped, the chunk will unload, the power will dip. So the
-- queue is built around one rule:
--
--   A step never trusts what was written down. It looks at the world first.
--
-- Every step declares a `verify` that answers "is this already done?" against
-- the actual machines, and a `run` that performs it. On resume the recorded step
-- number only says where to look; `verify` decides whether to skip. That is what
-- makes a crash between "the Mutatron produced a queen" and "I wrote that down"
-- harmless: the queen is visible, so the step is skipped.
--
-- The queue is persisted after every state change, never in the middle of one.

local state = require("lib.state")

local jobs = {}

-- What a step's run() may answer
jobs.DONE = "done"       -- step achieved, move to the next one
jobs.RETRY = "retry"     -- nothing wrong, just not now (no energy, machine busy)
jobs.FAILED = "failed"   -- this job cannot proceed
-- A hand is needed, and only a hand: a Gendustry input slot that refuses
-- automated extraction, an empty tank, a consumable the network does not hold.
-- Answering FAILED there killed jobs over a five second gesture, and RETRY
-- parked them silently so nobody ever learned what to do. This one carries the
-- gesture itself and never counts as an attempt: a job waiting on a human is
-- not a job going wrong.
jobs.NEEDS_PLAYER = "needs_player"

-- Job lifecycle
jobs.PENDING = "pending"
jobs.RUNNING = "running"
jobs.COMPLETE = "complete"
jobs.ERROR = "error"
jobs.CANCELLED = "cancelled"
jobs.WAITING = "waiting"   -- parked on a gesture, resumed by the player

--- What each kind and each state is called on screen
--- The keys are internal names -- "campaign", "pending" -- and they were being
--- printed raw. Nobody reading "campaign etape 6/7" learns what the machine is
--- doing or why it is stopped.
jobs.LABELS = {
    breed     = "croisement",
    multiply  = "accumulation de drones",
    sample    = "extraction d un gene",
    duplicate = "copie d un gene",
    campaign  = "chasse a un gene",
    imprint   = "impression sur abeille",
    replicate = "replication d une reine",
    extract   = "abeilles -> ADN",

    pending   = "en attente",
    running   = "en cours",
    complete  = "terminee",
    cancelled = "annulee",
    failed    = "echouee",
    waiting   = "attend un geste",
}

--- What a job is trying to obtain, in a few words
--- "#25 croisement" tells a reader nothing when ten crosses are in flight.
--- The goal is in the parameters; only the naming of a species uid has to come
--- from outside, because the queue has no registry.
--- @param job table
--- @param naming function|nil uid -> display name
--- @return string|nil goal
function jobs.goal(job, naming)
    local params = job and job.params
    if type(params) ~= "table" then return nil end

    local function named(uid)
        if type(uid) ~= "string" then return nil end
        if naming then
            local ok, display = pcall(naming, uid)
            if ok and display then return display end
        end
        return uid
    end

    if job.kind == "breed" then return named(params.target) end
    if job.kind == "multiply" then return params.species end

    if job.kind == "campaign" then
        if params.chromosome then
            return params.chromosome
                .. (params.allele and (" " .. params.allele) or "")
        end
    end

    local bee = params.bee or params.sample
    if type(bee) == "table" and bee.label then
        return (tostring(bee.label):gsub("%s+Drone$", ""))
    end

    return nil
end

--- What an outcome is called on screen
--- done, retry and needs_player are internal names that leaked into the log.
--- @param outcome string
--- @return string
function jobs.outcomeLabel(outcome)
    if outcome == jobs.DONE then return "fait" end
    if outcome == jobs.RETRY then return "plus tard" end
    if outcome == jobs.NEEDS_PLAYER then return "IL FAUT TA MAIN" end
    if outcome == jobs.FAILED then return "ECHEC" end
    return tostring(outcome)
end

--- Name something for a human, falling back to the internal name
--- A kind added later shows its own name rather than disappearing.
--- @param key string|nil
--- @return string
function jobs.label(key)
    return jobs.LABELS[key] or tostring(key)
end

jobs.DEFAULT_MAX_ATTEMPTS = 3

local Queue = {}
Queue.__index = Queue

--- Create a job queue
--- @param options table|nil {path, handlers, maxAttempts, clock}
---   handlers  map of job type -> {steps = {{name, verify, run}, ...}}
---   clock     function returning a timestamp, injectable for tests
--- @return table queue
function jobs.new(options)
    options = options or {}

    return setmetatable({
        path = options.path or state.pathFor("jobs"),
        handlers = options.handlers or {},
        maxAttempts = options.maxAttempts or jobs.DEFAULT_MAX_ATTEMPTS,
        clock = options.clock or os.time,
        data = {nextId = 1, queue = {}},
        loaded = false,
    }, Queue)
end

--- Read the queue back from disk, once
--- @return boolean ok
--- @return string|nil error
function Queue:load()
    if self.loaded then return true end
    self.loaded = true

    local stored, err = state.load(self.path, nil)

    if err then
        -- Losing the queue is bad, but refusing to boot because of it is worse:
        -- report and start clean so the operator can decide.
        return false, "file de taches illisible, elle repart vide: " .. err
    end

    if stored and type(stored.queue) == "table" then
        self.data = stored
        self.data.nextId = stored.nextId or 1
    end

    return true
end

--- Persist the queue
--- @return boolean ok
--- @return string|nil error
function Queue:save()
    return state.save(self.path, self.data)
end

--- Queue a new job
--- @param kind string Job type, must have a registered handler
--- @param params table|nil Parameters carried through every step
--- @return number|nil id
--- @return string|nil error
function Queue:submit(kind, params)
    self:load()

    if type(kind) ~= "string" then return nil, "type de tache invalide" end
    if not self.handlers[kind] then return nil, "aucun gestionnaire pour: " .. kind end

    local id = self.data.nextId
    self.data.nextId = id + 1

    table.insert(self.data.queue, {
        id = id,
        kind = kind,
        params = params or {},
        step = 1,
        status = jobs.PENDING,
        attempts = 0,
        created = self.clock(),
        updated = self.clock(),
    })

    local ok, err = self:save()
    if not ok then return nil, err end

    return id
end

--- Fetch a job by id
--- @param id number
--- @return table|nil job
function Queue:get(id)
    self:load()

    for _, job in ipairs(self.data.queue) do
        if job.id == id then return job end
    end

    return nil
end

--- Every job, in submission order
--- @param status string|nil Filter on a status
--- @return table[] jobs
function Queue:list(status)
    self:load()

    if not status then return self.data.queue end

    local filtered = {}
    for _, job in ipairs(self.data.queue) do
        if job.status == status then table.insert(filtered, job) end
    end

    return filtered
end

--- Jobs still waiting to advance
--- A job left in RUNNING by a crash counts as pending again: that is exactly the
--- resume case, and its steps re-verify before acting.
--- @return table[] jobs
function Queue:pending()
    self:load()

    local waiting = {}
    for _, job in ipairs(self.data.queue) do
        if job.status == jobs.PENDING or job.status == jobs.RUNNING then
            table.insert(waiting, job)
        end
    end

    return waiting
end

--- Jobs stopped on a gesture only the player can make
--- Deliberately NOT in pending(): the queue would pick them up again on the
--- same pass, fail on the same slot, and print the same instruction forever.
--- @return table[] jobs
function Queue:waiting()
    self:load()

    local held = {}
    for _, job in ipairs(self.data.queue) do
        if job.status == jobs.WAITING then table.insert(held, job) end
    end

    return held
end

--- Put a waiting job back in the queue, the gesture having been made
--- The step is not advanced: it re-verifies against the world, so telling the
--- program the slot is clear when it is not costs one pass, not a wrong action.
--- @param id number
--- @return boolean ok
--- @return string|nil error
function Queue:resume(id)
    local job = self:get(id)
    if not job then return false, "tache introuvable" end

    if job.status ~= jobs.WAITING then
        return false, "cette tache n attend pas de geste"
    end

    job.status = jobs.PENDING
    job.action = nil
    job.attempts = 0
    job.updated = self.clock()

    return self:save()
end

--- Put every waiting job back in the queue
--- @return number resumed
function Queue:resumeAll()
    local count = 0

    for _, job in ipairs(self:waiting()) do
        if self:resume(job.id) then count = count + 1 end
    end

    return count
end

--- Stop a job without running it further
--- @param id number
--- @return boolean ok
--- @return string|nil error
function Queue:cancel(id)
    local job = self:get(id)
    if not job then return false, "tache introuvable" end

    if job.status == jobs.COMPLETE then
        return false, "tache deja terminee"
    end

    job.status = jobs.CANCELLED
    job.updated = self.clock()

    return self:save()
end

--- Drop finished jobs from the queue
--- @return number removed
function Queue:prune()
    self:load()

    local kept = {}
    local removed = 0

    for _, job in ipairs(self.data.queue) do
        if job.status == jobs.COMPLETE or job.status == jobs.CANCELLED then
            removed = removed + 1
        else
            table.insert(kept, job)
        end
    end

    if removed > 0 then
        self.data.queue = kept
        self:save()
    end

    return removed
end

--- Advance one job by a single step
--- @param job table
--- @param context table Passed through to verify/run: machines, transport, ui
--- @param announce function|nil Called (job, name, index, total) when the step
---   is about to really run. NOT called for a step verify found already done:
---   those are instantaneous and were most of what the log printed.
--- @return string outcome One of jobs.DONE, jobs.RETRY, jobs.FAILED
--- @return string|nil detail
function Queue:step(job, context, announce)
    self:load()

    local handler = self.handlers[job.kind]
    if not handler or type(handler.steps) ~= "table" then
        -- A job outlives the code that ran it: a kind removed from the program
        -- leaves its jobs in the queue for good, failing every pass with a
        -- message that names the problem and not the remedy.
        job.status = jobs.ERROR
        job.error = "type de tache '" .. tostring(job.kind)
            .. "' inconnu du programme. Soit lib/ est plus ancien que la file"
            .. " (relance hminstall), soit ce type n existe plus:"
            .. " annule la tache #" .. tostring(job.id) .. "."
        job.updated = self.clock()
        self:save()
        return jobs.FAILED, job.error
    end

    -- Past the last step means the job is done
    if job.step > #handler.steps then
        job.status = jobs.COMPLETE
        job.updated = self.clock()
        self:save()
        return jobs.DONE, "tache terminee"
    end

    local step = handler.steps[job.step]
    job.status = jobs.RUNNING
    job.updated = self.clock()
    -- Written down BEFORE acting, so a crash during the step is seen on resume
    self:save()

    -- Ask the world whether this was already achieved. This is what makes a
    -- crash between acting and recording harmless.
    if type(step.verify) == "function" then
        local ok, achieved = pcall(step.verify, job, context)
        if ok and achieved then
            job.step = job.step + 1
            job.attempts = 0
            job.error = nil
            job.action = nil
            -- Leaving RUNNING here made a merely waiting job look busy in every
            -- report, and only pending() accepting both statuses kept the queue
            -- from stalling on it.
            job.status = (job.step > #handler.steps) and jobs.COMPLETE or jobs.PENDING
            job.updated = self.clock()
            self:save()
            return jobs.DONE, "etape deja accomplie: " .. tostring(step.name)
        end
    end

    -- Said before the work, because a step can hold a machine for two minutes
    -- and a silent pause is indistinguishable from a frozen program. Said
    -- HERE, because a step already accomplished takes no time at all.
    if type(announce) == "function" then
        pcall(announce, job, step.name, job.step, #handler.steps)
    end

    if type(step.run) ~= "function" then
        job.status = jobs.ERROR
        job.error = "etape sans action: " .. tostring(step.name)
        self:save()
        return jobs.FAILED, job.error
    end

    local ok, outcome, detail = pcall(step.run, job, context)

    if not ok then
        -- An error thrown inside a step is a failure, not a crash of the queue
        outcome, detail = jobs.FAILED, tostring(outcome)
    end

    if outcome == jobs.RETRY then
        job.status = jobs.PENDING
        job.error = detail
        job.updated = self.clock()
        self:save()
        return jobs.RETRY, detail
    end

    -- Waiting on a hand is not an attempt. Counting it would retire a job after
    -- three passes for something the player had simply not done yet, and the
    -- job would die exactly when the gesture was about to be made.
    if outcome == jobs.NEEDS_PLAYER then
        job.status = jobs.WAITING
        job.action = detail or "un geste est necessaire, la raison n a pas ete dite"
        job.error = nil
        job.updated = self.clock()
        self:save()
        return jobs.NEEDS_PLAYER, job.action
    end

    if outcome == jobs.DONE or outcome == true then
        job.step = job.step + 1
        job.attempts = 0
        job.error = nil
        -- The gesture that was asked for has served its purpose; leaving it
        -- written would keep showing a chore that is already done
        job.action = nil
        job.status = (job.step > #handler.steps) and jobs.COMPLETE or jobs.PENDING
        job.updated = self.clock()
        self:save()
        return jobs.DONE, detail
    end

    -- Anything else is a failure; give it a few tries before giving up
    job.attempts = (job.attempts or 0) + 1
    job.error = detail or "echec sans raison"
    job.updated = self.clock()

    if job.attempts >= self.maxAttempts then
        job.status = jobs.ERROR
    else
        job.status = jobs.PENDING
    end

    self:save()
    return jobs.FAILED, job.error
end

--- Advance the queue until nothing can move
--- Stops on the first job that fails permanently, so the operator sees it rather
--- than having it buried under later work.
--- @param context table Passed to every step
--- @param options table|nil {maxSteps, budget, onStep, onProgress}
--- onStep fires BEFORE a step runs. A step can wait two minutes on a machine
--- without printing anything, and a silent pause is indistinguishable from a
--- frozen program.
--- @return table report {steps, completed, retried, failed, blocked}
function Queue:run(context, options)
    options = options or {}
    self:load()

    local report = {steps = 0, completed = 0, retried = 0, failed = 0,
                    waiting = 0, blocked = false, exhausted = false}
    local limit = options.maxSteps or 1000

    -- A campaign that keeps succeeding keeps going: thirty cycles of several
    -- minutes each is a run that never reports back, and from outside that is
    -- indistinguishable from a hang. The budget stops the pass, not the work --
    -- everything is on disk and the next pass resumes.
    local budget = options.budget
    local startedAt = self.clock()

    -- A job that answered RETRY is waiting, not failing, and there is usually
    -- other work behind it. Stopping the whole pass on it meant one bee missing
    -- from the network kept every later job from moving, including the campaign
    -- meant to produce that very bee.
    local parked = {}

    while report.steps < limit do
        local job = nil
        for _, candidate in ipairs(self:pending()) do
            if not parked[candidate.id] then job = candidate break end
        end
        if not job then break end

        if budget and (self.clock() - startedAt) >= budget then
            report.exhausted = true
            break
        end

        local before_step = job.step

        local handler = self.handlers[job.kind]
        local total = handler and handler.steps and #handler.steps or 0

        local outcome, detail = self:step(job, context, options.onStep)
        report.steps = report.steps + 1

        if type(options.onProgress) == "function" then
            pcall(options.onProgress, job, outcome, detail, before_step, total)
        end

        if outcome == jobs.DONE then
            if job.status == jobs.COMPLETE then report.completed = report.completed + 1 end
        elseif outcome == jobs.NEEDS_PLAYER then
            -- Not counted as blocked: the pass is not stuck, it has a chore to
            -- hand back. Calling that "bloquee" told the player to go looking
            -- for a cause the program had already identified.
            report.waiting = report.waiting + 1
            parked[job.id] = true
        elseif outcome == jobs.RETRY then
            report.retried = report.retried + 1
            -- Set aside for this pass rather than retried immediately, which
            -- would spin, or aborting everything, which would starve the rest
            report.blocked = true
            parked[job.id] = true
        else
            report.failed = report.failed + 1
            -- A permanent failure is the one thing worth stopping for: the
            -- operator has to see it rather than find it buried under later work
            if job.status == jobs.ERROR then break end
            report.blocked = true
            parked[job.id] = true
        end

        -- Safety net against a verify/run pair that never advances. A job
        -- waiting on a gesture has not advanced either, and that is normal --
        -- flagging it blocked would send the player hunting for a fault while
        -- the program is holding out the exact thing to do.
        if job.step == before_step and job.status ~= jobs.COMPLETE
           and job.status ~= jobs.WAITING then
            report.blocked = true
            parked[job.id] = true
        end
    end

    return report
end

--- One-line summary per job, for the GUI and the logs
--- @return string[] lines
function Queue:describe()
    self:load()

    local lines = {}
    for _, job in ipairs(self.data.queue) do
        local handler = self.handlers[job.kind]
        local total = handler and handler.steps and #handler.steps or "?"
        -- The gesture comes before the error: a job that is waiting has no
        -- error, and what the reader needs is the thing to go and do
        local suffix = ""
        if job.action then
            suffix = "  -> " .. job.action
        elseif job.error then
            suffix = "  (" .. job.error .. ")"
        end

        table.insert(lines, string.format("#%-3d %-24s %-16s etape %s/%s%s",
            job.id, jobs.label(job.kind), jobs.label(job.status),
            tostring(job.step), tostring(total), suffix))
    end

    return lines
end

return jobs
