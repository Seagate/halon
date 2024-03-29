# RFC: Rules reconfiguration

## Introduction

This docuemnt contains a design proposal for supporting runtime Recovery
Coordinator updates.

## Purpose

In order for Halon to operate correctly, rules must be configured by options
that depend on a cluster layout. It should be possible to to set such options
on the fly. So administrator could change RC becaviour in case it work
incorrectly or suboptimaly. For this purpose Halon should provide a special
API that makes it easy to keep track options and update them.

## Constraints

  1. Rules update should not put RC into incorrect state:
     a. Rules that should finish transaction with the same values as they started
        should not be updated.
     b. Messages or actions should not be lost in option update arrive in the
        middle of the transaction.
  2. Rules update should be visible as soon as possible (this contraint should
      be better formulated by actual requirement, or remove if there is no such)
  3. Settings should have the same liveness as cluster has.

## Description

### User API.

In order to edit options user should be configure such options in the file
and load file at halon. For this purpose halon should provide two oprations

  halonctl download-settings  -- stores current settings in a file
  halonctl upload-setttings   -- upload settings to RC

When administrator uploads settings they are first checked by Halon and if
any failure was found there then error with failure description is thrown
(See Rule Processing section). If no failures were found then Recovery
Coordinator starts rule updating procedure.

(Optionaly in order to guarantee that administrator updates recent option
halon may add a UUID to options that were downloaded by user and reject to
update setting if value doesn't much current options value)

Implementation may choose to provide additional options for example for rule
validating rules without actual update, but this is not specified by this
RFC.

#### File format

File has is yaml format. It should be structured as follows:

group:
  subgroup:
    - option: value

Example:

```yaml
global:
  # Timeout that is used in rules (9000000000000)
  defaultTimeout: 100000
  # Email that is used to send alerts ()
  administrator.email: internal-support@seagate.com

"service-start":
  # Number of attempts to start a service (3)
  failure_attempts: 7

"buggy_rule"
  # If rule should be enabled
  enabled: False
```

#### Partial modification

Partial modification if supported may be allowed using halonctl command:

  halonctl set-option --section "sectionname" "option" "value 1"


### Rule update processing

There are 2 different types of options:

  1. rule options
  2. engine options

Rule options applied and used withing a rules. Examples: different constants
that are used in the rules. Such options can't affect how engine works and
do not need any special functionality from CEP.

Engine rules modify how engine process rules. Such options (command) could
require special functionality in CEP. Examples: if rule should be enabled or not.

#### Transactional options

Halon store all setting in the global state in a special data structure.
When rule performs an option lookup it receives most recent setting from
that structure. If rule need to keep the same value during transaction it
should store it in immutable storage. It could be:

  1. Local state - value in local state is the fastest way. However such value
      will not survive RC restart and will be lost.

  2. RG - value stored in resource graph as a part of the state update
      is relatevely slow.

As a result multistep rule may we written as follows:

```
  opt1 <- declareOption "example-rule" "hello" Just id "Hello"
  directly $ do
    option <- readOpiton opt1
    put Local option -- store option in a local storage
    continue ph1

  definePhase ph1 $ \(ExampleEvent pid name) -> do
    hello <- get Local -- read local version of the option
    liftProcess $ usend pid $ hello ++ ", " ++ name
```

#### Multivariant rules

If we need a list of the same rules, that run with a different option
we could do following trick:

```
  opt1 <- declareOption "example-rule" "hello" read print ["A"]
  directly $ do
    values <- readOption opt1
    forM values $ \value ->
      put Local value
      fork ph1
    stop
  definePhase ph1 $ ...
```

#### Engine rules

In order to support engine rules CEP shoud provide a number of callbacks,
that will modify engine.

Interesting callbacks are:

  - Disable rules by name:

    Disabling a rule is actually removal a rule from a lists of running
    rules and suspended rules.

  - Enable rules by name:

    Move rule from saved rules to running. Actually this rule will start
    a new rule with the given name.

Current rules are not serializable, so it's not possible to store a rule
to persistent storage. And this is a requirement for suspending and
restarting rules based on configuration settings.


#### Rules data structure

(All types are written for simplicity, actual implementation could
choose whatever type that preserve same semantics)
Data structure should support following options:

  type Section
  type OptionName
  data Option a =              - View that allow to read an option

  readOption :: Option a -> a  - Read current option value

  lookupOption :: Section -> Name -> Maybe (Option a)
    -- Lookup option object, this call may be required if it's not
       possible to pass Option into certain rule. May return Nothing
       if option was not declared.

  declareOption :: Section
                -> Name
                -> String              -- description
                -> (String -> Maybe a) -- parser
                -> (a -> String)       -- renderer
                -> a
                -> Declaration (Option a)
    -- Declare option inside CEP Engine. This call declare a parser,
       renderer and default value in the options. Returns an Option view.


  buildOptionsMap :: SettingDescription
                  -> [(String,String)]
                  -> Either [(String, String)] (Settings)
    -- Build new option from raw values

  readOptionMap :: SettingsDescription -> Section -> Name -> Settings
                -> Proxy a
                -> Maybe a
    -- read option from the storage

  writeOptionMap :: SettingsDescription -> Section -> Name -> Settings
                 -> a -> Settings
    -- write option to storage

  readOption :: Option  a -> PhaseM ... a
    -- read option value inside the rule

  writeOption :: Option a -> a -> PhaseM .. ()
    -- write new option value inside the rule

Inside RC engine user carry an data structure for options presented
as follows:

type SettingDescription = Map (Section, Name) (Proxy a, String, String -> Maybe a, a -> String)
type Settings = Map (Section, Name) Any

It's possible to implement this using unsafeCoerce that should be typesafe,
if we don't change RC in runtime, however if we do that we still have information
about types, and if type changes, we have to use default value. If using
of unsafe coerce worry user, we could choose implementation based on 
Typeable and safe coerce.

#### Rule processing

In order to see a rule updates - special rule is registered that works
as follows (other values in global type are ignored for simplicity)

````haskell
   define "settings-update" $ do
     request <- phaseHandle "request"
     commit <- phaseHandle "commit"
     setPhase $ \(HAEvent uuid (NewSettings newSettings sender) _)-> do
       (description, oldSettings) <- get Global
       let esettings = buildOptionMap description newSettings
       case esettings of
         Left errors -> do liftProcess $ usend sender (SettingsFailed errors)
                           sendMsg eq uuid
         Right settings -> do
            put Local (Just sender)
            put Global (description, settings)
            continue commit

   directly commit $ do
        Just sender <- get
        liftProcess $ usend sender SettingsUpdateOk
        sendMsg eq uuid
````

When RC finished execution of the step it checks in there is an option update
if so it stores option in replicated storage and locally and goes to the next
step. This event is acknowledged to EQ only when it was stored, i.e. on the
second step of the CEP rule. This guarantee that setting update will be processed
even in presence of network failures.
