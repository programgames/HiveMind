-- HiveMind job queue tests
--
-- The property under test is not "it runs steps in order". It is that killing
-- the computer at any moment and starting again produces the same outcome,
-- without repeating an action that already took effect in the world.

package.path = package.path .. ";./?.lua"

local jobs = require("lib.jobs")

local passed, failed = 0, 0

local function check(description, actual, expected)
    if actual == expected then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description
            .. "\n         obtenu  : " .. tostring(actual)
            .. "\n         attendu : " .. tostring(expected))
    end
end

local function checkTruthy(description, value)
    if value then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description)
    end
end

local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local PATH = TMP .. "/hivemind-jobs-test.lua"

local tick = 0
local function clock() tick = tick + 1 return tick end

-- A simulated world the steps act on, so "already done" is a real question
local world

local function freshWorld()
    world = {mutagen = 10, queenProduced = false, queenCollected = false, actions = {}}
end

local function record(action)
    table.insert(world.actions, action)
end

--- A breeding job whose steps look at the world before acting
local BREED = {
    steps = {
        {
            name = "load-parents",
            verify = function() return world.parentsLoaded end,
            run = function()
                record("load")
                world.parentsLoaded = true
                return jobs.DONE
            end,
        },
        {
            name = "produce-queen",
            verify = function() return world.queenProduced end,
            run = function()
                if world.mutagen <= 0 then
                    -- Not an error: the machine simply cannot work right now
                    return jobs.RETRY, "reservoir de mutagene vide"
                end
                record("produce")
                world.mutagen = world.mutagen - 1
                world.queenProduced = true
                return jobs.DONE
            end,
        },
        {
            name = "collect",
            verify = function() return world.queenCollected end,
            run = function()
                record("collect")
                world.queenCollected = true
                return jobs.DONE
            end,
        },
    },
}

local FLAKY_ATTEMPTS = 0
local FLAKY = {
    steps = {{
        name = "always-fails",
        run = function()
            FLAKY_ATTEMPTS = FLAKY_ATTEMPTS + 1
            return jobs.FAILED, "panne simulee"
        end,
    }},
}

-- Waits forever without ever failing: the shape of a job blocked on a bee the
-- network does not hold yet
local WAITING = {
    steps = {{
        name = "attend-toujours",
        run = function() return jobs.RETRY, "attend quelque chose" end,
    }},
}

local THROWING = {
    steps = {{
        name = "throws",
        run = function() error("exception dans l'etape") end,
    }},
}

local function newQueue()
    return jobs.new({
        path = PATH,
        handlers = {breed = BREED, flaky = FLAKY, throwing = THROWING,
                    waiting = WAITING},
        clock = clock,
    })
end

os.remove(PATH)
freshWorld()

print("=== Job queue tests ===")
print("")
print("-- soumission --")

local queue = newQueue()
local id, err = queue:submit("breed", {target = "Imperial"})
check("tache creee (" .. tostring(err) .. ")", id, 1)
check("type inconnu refuse", (queue:submit("inexistant")), nil)
check("statut initial", queue:get(id).status, jobs.PENDING)
check("parametres conserves", queue:get(id).params.target, "Imperial")

print("")
print("-- execution complete --")

local report = queue:run({})
check("3 etapes executees", report.steps, 3)
check("1 tache terminee", report.completed, 1)
check("statut final", queue:get(id).status, jobs.COMPLETE)
check("actions dans l'ordre", table.concat(world.actions, ","), "load,produce,collect")

print("")
print("-- reprise apres crash --")

-- Kill everything mid-job: the world keeps the effects, the queue is reloaded
os.remove(PATH)
freshWorld()

local crashing = newQueue()
crashing:submit("breed", {target = "Imperial"})
crashing:step(crashing:pending()[1], {})   -- load-parents
crashing:step(crashing:pending()[1], {})   -- produce-queen

check("deux etapes faites avant le crash", table.concat(world.actions, ","), "load,produce")

-- New process: nothing in memory, everything reread from disk
local resumed = newQueue()
local resumed_job = resumed:pending()[1]
checkTruthy("la tache interrompue est retrouvee", resumed_job)
check("reprise a la bonne etape", resumed_job.step, 3)

resumed:run({})
check("la tache s'acheve", resumed:get(1).status, jobs.COMPLETE)
check("aucune action rejouee", table.concat(world.actions, ","), "load,produce,collect")

print("")
print("-- crash entre l'action et son enregistrement --")

-- The nastiest case: the machine acted, the queue never got to write it down.
-- On resume the step number is stale, and only verify() can save us.
os.remove(PATH)
freshWorld()

local stale = newQueue()
stale:submit("breed", {})
stale:step(stale:pending()[1], {})     -- load-parents recorded

-- The world moves on without the queue knowing
world.queenProduced = true
record("produce")

local recovered = newQueue()
recovered:run({})

check("l'etape deja accomplie est sautee", table.concat(world.actions, ","),
      "load,produce,collect")
check("le mutagene n'a pas ete consomme deux fois", world.mutagen, 10)
check("tache terminee malgre l'ecart", recovered:get(1).status, jobs.COMPLETE)

print("")
print("-- attente (RETRY) --")

os.remove(PATH)
freshWorld()
world.mutagen = 0   -- machine unable to work

local waiting = newQueue()
waiting:submit("breed", {})
local waiting_report = waiting:run({})

check("la file signale un blocage", waiting_report.blocked, true)
check("une attente comptee", waiting_report.retried, 1)
check("la tache reste en attente, pas en erreur", waiting:get(1).status, jobs.PENDING)
check("raison conservee", waiting:get(1).error, "reservoir de mutagene vide")
check("l'etape n'a pas avance", waiting:get(1).step, 2)

-- Supply the machine and come back: it picks up where it stopped
world.mutagen = 5
waiting:run({})
check("reprise apres approvisionnement", waiting:get(1).status, jobs.COMPLETE)
check("aucune etape rejouee", table.concat(world.actions, ","), "load,produce,collect")

print("")
print("-- echec repete --")

os.remove(PATH)
FLAKY_ATTEMPTS = 0

local failing = jobs.new({path = PATH, handlers = {flaky = FLAKY}, clock = clock,
                          maxAttempts = 3})
failing:submit("flaky", {})

for _ = 1, 5 do failing:run({}) end

check("statut d'erreur apres 3 tentatives", failing:get(1).status, jobs.ERROR)
check("tentatives plafonnees", FLAKY_ATTEMPTS, 3)
check("raison conservee", failing:get(1).error, "panne simulee")

print("")
print("-- une exception dans une etape ne tue pas la file --")

os.remove(PATH)
local throwing = jobs.new({path = PATH, handlers = {throwing = THROWING}, clock = clock,
                           maxAttempts = 1})
throwing:submit("throwing", {})
local throwing_report = throwing:run({})

check("l'exception devient un echec", throwing_report.failed, 1)
check("tache en erreur", throwing:get(1).status, jobs.ERROR)
checkTruthy("message d'exception conserve",
            throwing:get(1).error and throwing:get(1).error:find("exception"))

print("")
print("-- annulation et nettoyage --")

os.remove(PATH)
freshWorld()

local managed = newQueue()
local a = managed:submit("breed", {})
local b = managed:submit("breed", {})

checkTruthy("annulation reussie", managed:cancel(b))
check("statut annule", managed:get(b).status, jobs.CANCELLED)
check("une seule tache en attente", #managed:pending(), 1)
check("annulation d'une tache absente", (managed:cancel(999)), false)

managed:run({})
check("la tache restante s'execute", managed:get(a).status, jobs.COMPLETE)
check("2 taches purgees", managed:prune(), 2)
check("file vide apres purge", #managed:list(), 0)

print("")
print("-- une tache en attente ne bloque pas les suivantes --")

-- The queue used to abort the whole pass on the first RETRY. In game that meant
-- a job waiting for a drone kept the campaign meant to produce that drone from
-- ever starting.
os.remove(PATH)
freshWorld()

local shared = newQueue()
local blockedId = shared:submit("waiting", {})
local followerId = shared:submit("breed", {target = "Common"})

local pass = shared:run(context, {maxSteps = 40})

check("la tache en attente reste en attente",
      shared:get(blockedId).status, jobs.PENDING)
check("la tache suivante va au bout",
      shared:get(followerId).status, jobs.COMPLETE)
checkTruthy("la passe est signalee comme bloquee", pass.blocked)
checkTruthy("l'attente est comptee", pass.retried >= 1)

-- And it must not spin on the parked job to get there
checkTruthy("aucune boucle sur la tache en attente", pass.steps < 40)

print("")
print("-- une panne definitive arrete quand meme la passe --")

os.remove(PATH)
freshWorld()
FLAKY_ATTEMPTS = 0

local halting = jobs.new({path = PATH,
                          handlers = {flaky = FLAKY, breed = BREED},
                          clock = clock, maxAttempts = 1})
local brokenId = halting:submit("flaky", {})
local afterId = halting:submit("breed", {target = "Common"})

halting:run(context, {maxSteps = 40})

check("la tache en panne est en erreur", halting:get(brokenId).status, jobs.ERROR)
check("la suivante n'a pas ete entamee", halting:get(afterId).step, 1)

print("")
print("-- une passe rend la main dans le temps imparti --")

-- A campaign that keeps succeeding keeps going. Thirty cycles of several
-- minutes each is a run that never reports back, and from outside that looks
-- exactly like a hang.
os.remove(PATH)
freshWorld()

local LOOPING = {steps = {
    {name = "travaille", run = function() return jobs.DONE end},
    {name = "recommence", run = function(job)
        job.step = 0            -- back to step one, as a campaign does
        return jobs.DONE
    end},
}}

local endless = jobs.new({
    path = PATH,
    handlers = {loop = LOOPING},
    clock = clock,
})

endless:submit("loop", {})
local bounded = endless:run(context, {maxSteps = 5000, budget = 20})

checkTruthy("la passe s'arrete d'elle-meme", bounded.exhausted)
checkTruthy("elle a quand meme travaille", bounded.steps > 0)
checkTruthy("elle n'a pas epuise maxSteps", bounded.steps < 5000)
check("la tache reste reprenable", endless:get(1).status, jobs.PENDING)

-- Without a budget the same job would run until maxSteps
os.remove(PATH)
local unbounded = jobs.new({path = PATH, handlers = {loop = LOOPING}, clock = clock})
unbounded:submit("loop", {})
local free = unbounded:run(context, {maxSteps = 40})
check("sans budget, seul maxSteps arrete", free.steps, 40)
check("et rien ne signale un temps ecoule", free.exhausted, false)

print("")
print("-- persistance de la file --")

os.remove(PATH)
freshWorld()

local persisted = newQueue()
persisted:submit("breed", {target = "Wintry"})

local reread = newQueue()
check("tache relue depuis le disque", reread:get(1).params.target, "Wintry")
check("compteur d'id conserve", reread:submit("breed", {}), 2)

local lines = reread:describe()
check("une ligne par tache", #lines, 2)
checkTruthy("la ligne nomme le type en clair",
            lines[1]:find("croisement", 1, true))
checkTruthy("et son etat aussi", lines[1]:find("en attente", 1, true))

os.remove(PATH)

print("")
print("-- une tache dont le type a disparu du programme --")

-- A job outlives the code that ran it. A kind removed from the program leaves
-- its jobs failing every pass with a message that named the problem and not the
-- remedy: "aucun gestionnaire pour: template".
os.remove(PATH)
freshWorld()

local writer = jobs.new({path = PATH, handlers = {breed = BREED, flaky = FLAKY},
                         clock = clock})
local orphanId = writer:submit("flaky", {})

-- A later version of the program, without that job type
local orphaned = jobs.new({path = PATH, handlers = {breed = BREED}, clock = clock})
orphaned:run(context, {maxSteps = 10})

check("la tache est en erreur", orphaned:get(orphanId).status, jobs.ERROR)
checkTruthy("le type inconnu est nomme",
            orphaned:get(orphanId).error and orphaned:get(orphanId).error:find("flaky"))
checkTruthy("le numero a annuler est donne",
            orphaned:get(orphanId).error
            and orphaned:get(orphanId).error:find("#" .. orphanId))
checkTruthy("les deux causes possibles sont citees",
            orphaned:get(orphanId).error
            and orphaned:get(orphanId).error:find("hminstall"))

-- And it must not take the rest of the queue with it
local companion = orphaned:submit("breed", {target = "Common"})
orphaned:run(context, {maxSteps = 20})
check("les autres taches passent quand meme",
      orphaned:get(companion).status, jobs.COMPLETE)

print("")
print("")
print("-- ce que la file dit a l'ecran --")

do
    -- "campaign etape 6/7" tells a reader neither what the machine is doing nor
    -- why it stopped. Every internal name gets a French one.
    check("chaque type de tache a un nom lisible",
          jobs.label("campaign"), "chasse a un gene")
    check("et chaque etat aussi", jobs.label("pending"), "en attente")

    -- A kind added later must show its own name rather than vanish
    check("un type inconnu se nomme lui-meme",
          jobs.label("quelque_chose"), "quelque_chose")
    check("et nil ne casse rien", jobs.label(nil), "nil")

    local every = {"breed", "multiply", "sample", "duplicate", "campaign",
                   "imprint", "replicate", "extract"}
    local missing = {}
    for _, kind in ipairs(every) do
        if jobs.LABELS[kind] == nil then table.insert(missing, kind) end
    end
    check("aucun type de tache n'est oublie: "
          .. (#missing > 0 and table.concat(missing, " ") or "-"), #missing, 0)

    for _, state in ipairs({jobs.PENDING, jobs.RUNNING, jobs.COMPLETE,
                            jobs.CANCELLED, jobs.FAILED}) do
        if jobs.LABELS[state] == nil then table.insert(missing, state) end
    end
    check("ni aucun etat", #missing, 0)
end

print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests de la file passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
