-- | Scope and lower four authoring capabilities. Validation gets only catalog
-- metadata and immutable data; publication owns the commit/cache boundary.
module Max.Skill.ToolRuntime (skillAuthoringToolsWithDatabase) where

import Data.Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.Effects.SkillDraft
import Max.Effects.SkillPublication
import Max.Effects.SkillQuery
import Max.Effects.SkillValidation
import Max.Effects.Tools (Tool, hoistTool)
import Max.Skill.Authoring
import Max.Skill.Load (resolveSkillLoads)
import Max.Skill.Package (SkillEvidence (..))
import Max.Skill.Store
import Max.Skill.Validation (validateFixtures)
import Max.Skill.Workflow (bindWorkflowContracts, publicationContract)
import Max.Skills
import Max.Tool.Bundles (SkillLoad (..), checkSkillLoadBudget)
import Max.Tool.Types
import Max.ToolContext
import Max.Tools.SkillAuthoring (skillAuthoringTools)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)
import OneBot.Types (GroupId (..))

skillAuthoringToolsWithDatabase :: forall es. (WithConnection :> es, IOE :> es) => SkillRegistry -> ToolContext -> Either Text [CatalogTool] -> [Tool es]
skillAuthoringToolsWithDatabase registry context catalog = map (hoistTool lower) skillAuthoringTools
  where
    scope = AuthoringScope (toolGroupId context) (toolAuthorPrincipalId context) (toolCanonicalId context) ((.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context)
    lower :: forall a. Eff (SkillDraft : SkillQuery : SkillValidation : SkillPublication : es) a -> Eff es a
    lower =
      runSkillPublication publishDraft
        . runSkillValidation (\name revision -> raise (validate name revision))
        . runSkillQuery (\name revision -> raise (raise (inspectDraft scope name revision)))
        . runSkillDraft (\draft expected -> raise (raise (raise (save draft expected))))
    save draft expected = do
      permitted <- checkName draft.dcName
      case permitted of
        Left err -> pure (Left err)
        Right () -> saveDraft scope draft expected
    checkName name = do
      allSkills <- liftIO (listAllSkills registry)
      pure $
        if "learned-task-" `T.isPrefixOf` name || any (\s -> s.skillId < 0 && s.skillName == name) allSkills
          then Left "builtin and learned-task names are reserved"
          else Right ()
    prepare draft = do
      permitted <- checkName draft.dvContent.dcName
      case permitted >> validateDraft draft.dvContent >> catalog of
        Left err -> pure (Left err)
        Right current -> do
          snapshot <- liftIO (skillsForGroup registry (toolGroupId context))
          now <- liftIO getCurrentTime
          let content = draft.dvContent
              GroupId gid = toolGroupId context
              candidate = Skill 0 content.dcName (Just gid) content.dcDescription content.dcBody True Nothing now draft.dvRevision content.dcPackage TrustedSkill
              visible = Map.insert content.dcName candidate (Map.fromList [(s.skillName, s) | s <- snapshot])
              metadata name
                | name == content.dcName = pure (Right Nothing)
                | Just loaded <- Map.lookup name (toolSkillLoads context) = pure (Right loaded.slMetadata)
                | otherwise = pure (Left ("load the complete dependency skill first: " <> name))
              denied t = let name = t.ctDefinition.tdRef.unToolRef in t.ctDefinition.tdCallMode /= WorkCall || EffectReflect `Set.member` t.ctDefinition.tdEffects || "skill_" `T.isPrefixOf` name || "task_" `T.isPrefixOf` name
          resolved <- liftIO (resolveSkillLoads visible Map.empty metadata content.dcName)
          pure $ do
            loads <- resolved >>= bindWorkflowContracts javaScriptRuntimeVersion Map.empty current >>= checkSkillLoadBudget Map.empty
            let leaves = [t | t <- current, t.ctDefinition.tdRef.unToolRef `elem` authoredTools content.dcPackage]
            if any denied leaves
              then Left "authored workflows cannot call authoring or loop/task control tools"
              else do
                if any (\l -> l.slName /= content.dcName && fmap (.slVersion) (Map.lookup l.slName (toolSkillLoads context)) /= Just l.slVersion) loads
                  then Left "a dependency differs from this turn's pinned version; use a new turn"
                  else case filter ((== content.dcName) . (.slName)) loads of
                    [root] -> Right (validationContext draft.dvRevision (publicationContract javaScriptRuntimeVersion root loads), leaves)
                    _ -> Left "validation root missing"
    validate name revision = do
      active <- authoringCallerActive scope
      found <- if active then readDraft scope name revision else pure (Left "skill authoring caller is fenced")
      case found of
        Left err -> pure (Left err)
        Right draft -> do
          prepared <- prepare draft
          case prepared of
            Left err -> pure (Left err)
            Right (frozen, leaves) -> do
              report <- liftIO (validateFixtures leaves draft)
              recordValidation scope name revision frozen report
    publishDraft name revision proof expected = do
      result <- publishSkillTransaction registry $ do
        found <- readDraft scope name revision
        case found of
          Left err -> pure (Left err)
          Right draft -> do
            prepared <- prepare draft
            case prepared of
              Left err -> pure (Left err)
              Right (frozen, _) -> promoteDraftWithin scope draft proof expected frozen
      pure $ fmap (\s -> object ["name" .= s.skillName, "revision" .= s.skillRevision, "draft_revision" .= revision, "available_on_next_load" .= True]) result
