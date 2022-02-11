module Test.Main where

import Prologue

import Control.Monad.Reader (ask)
import Control.Monad.State (class MonadState)
import Data.Array as Array
import Data.Int (decimal)
import Data.Int as Int
import Data.Undefinable (toUndefinable)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import Halogen (Component, HalogenIO)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties.ARIA as HP
import Halogen.Subscription as HS
import Test.Halogen (runUITest)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner (runSpec)
import Test.Web (runTestMInBody)
import Test.Web.DOM.Assertions (shouldHaveId, shouldHaveTagName, shouldHaveText)
import Test.Web.DOM.Query (byRoleDefault, findBy, getBy, role, role')
import Test.Web.Event.User (click, runUserM)
import Test.Web.Monad (getContainer)
import Web.ARIA (ARIARole(..))
import Web.DOM (Element)

main :: Effect Unit
main = launchAff_ $ runSpec [ consoleReporter ] do
  testingLibrarySpec
  halogenTestingLibrarySpec

-------------------------------------------------------------------------------
-- Demo tests for purescript-testing-library
-------------------------------------------------------------------------------

foreign import setupTestApp :: Element -> Effect Unit

testingLibrarySpec :: Spec Unit
testingLibrarySpec = do
  describe "testing-library" do
    it "works with JSDOM" do
      runUserM Nothing $ runTestMInBody do
        body <- getContainer
        body `shouldHaveTagName` "body"
        liftEffect $ setupTestApp body
        paragraph <- getBy $ role Paragraph
        paragraph `shouldHaveId` "para"
        paragraph `shouldHaveTagName` "p"
        paragraph `shouldHaveText` "Test content"
        -- TODO add clickM
        -- clickM $ findBy $ role Button
        click =<< findBy (role Button)
        paragraph `shouldHaveText` "It worked!"

-- getBy, findBy, role are from `purescript-testing-library`
-- click is from `purescript-user-event`

-------------------------------------------------------------------------------
-- Demo tests for halogen-testing-library
-------------------------------------------------------------------------------

-- Simple Counter component

data Query a
  = GetValue (Int -> a)
  | SetValue Int a

data Action
  = Receive Int
  | Increment
  | Decrement

counter :: Component Query Int Int Aff
counter = H.mkComponent
  { initialState: identity
  , render
  , eval: H.mkEval H.defaultEval
      { receive = Just <<< Receive
      , handleAction = handleAction
      , handleQuery = handleQuery
      }
  }
  where
  handleAction = case _ of
    Receive v -> H.put v
    Increment -> H.raise =<< H.modify (_ + 1)
    Decrement -> H.raise =<< H.modify (_ - 1)
  render state =
    HH.div_
      [ HH.button [ HE.onClick $ const Decrement ] [ HH.text "-" ]
      , HH.span [ HP.role "textbox" ]
          [ HH.text $ Int.toStringAs decimal state ]
      , HH.button [ HE.onClick $ const Increment ] [ HH.text "+" ]
      ]

handleQuery
  :: forall m a. Functor m => MonadState Int m => Query a -> m (Maybe a)
handleQuery = case _ of
  GetValue k -> map (Just <<< k) H.get
  SetValue n a -> do
    H.put n
    pure $ Just a

-- Component Spec

halogenTestingLibrarySpec :: Spec Unit
halogenTestingLibrarySpec = do
  describe "halogen-testing-library" do

    it "Receives the initial input" do
      -- runUITest is from purescript-halogen-testing-library. It is similar to
      -- runUI:
      --
      -- driver <- runUI counter 10 element
      runUITest counter 10 do
        span <- getBy $ role Textbox
        span `shouldHaveText` "10"

    it "Handles user interaction" do
      runUITest counter 0 do
        decrement <- getBy $ role' Button byRoleDefault
          { name = toUndefinable $ Just "-"
          }
        increment <- getBy $ role' Button byRoleDefault
          { name = toUndefinable $ Just "+"
          }
        span <- getBy (role Textbox)
        click increment
        span `shouldHaveText` "1"
        click decrement
        click decrement
        span `shouldHaveText` "-1"

    it "Sends messages" do
      runUITest counter 0 do
        decrement <- getBy $ role' Button byRoleDefault
          { name = toUndefinable $ Just "-"
          }
        increment <- getBy $ role' Button byRoleDefault
          { name = toUndefinable $ Just "+"
          }

        -- TODO move this to internals of runUITest so this can be rewritten
        -- as:
        --
        -- click increment
        -- click decrement
        -- expectMessages [ 1, 0 ]
        -- click increment
        -- expectMessages [ 1 ]
        messagesRef <- liftEffect $ Ref.new []
        { messages } <- ask
        void $ liftEffect $ HS.subscribe messages \i ->
          Ref.modify_ (flip Array.snoc i) messagesRef
        click increment
        click decrement
        flip shouldEqual [ 1, 0 ] =<< liftEffect (Ref.read messagesRef)

    it "Handles queries" do
      runUITest counter 0 do
        increment <- getBy $ role' Button byRoleDefault
          { name = toUndefinable $ Just "+"
          }
        span <- getBy (role Textbox)
        click increment
        click increment
        -- TODO add helper function so we can do this instead:
        --
        -- value <- TH.request GetValue
        { query } :: HalogenIO Query Int Aff <- ask
        value <- liftAff $ query (H.mkRequest GetValue)
        value `shouldEqual` Just 2
        -- TODO add helper function so we can do this instead:
        --
        -- TH.tell $ SetValue 10
        void $ liftAff $ query (H.mkTell (SetValue 10))
        span `shouldHaveText` "10"

--     it "Can be debugged" do
--       runUITest counter 0 do
--         increment <- getBy $ role' Button byRoleDefault
--           { name = toUndefinable $ Just "+"
--           }
--         span <- getBy (role Textbox)
--         click increment
--         click increment
--         debugElement increment
--         debugElements [ increment, span ]
--         logTestingPlaygroundURL
