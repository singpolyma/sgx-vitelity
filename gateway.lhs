We need this language extension because the "monads-tf" package uses an already used module name, unfortunately.

> {-# LANGUAGE PackageImports #-}

Only exporting the main function allows GHC to do more optimisations inside.

> module Main (main) where

Switch to BasicPrelude because it's nice.

> import Prelude ()
> import BasicPrelude hiding (log)

Import all the things!

> import Data.Char
> import Control.Concurrent
> import Control.Concurrent.STM
> import Data.Time (getCurrentTime)
> import Control.Error (runExceptT, syncIO, readZ)
> import Network (PortID(PortNumber))
> import System.IO (stdout, stderr, hSetBuffering, BufferMode(LineBuffering))
> import System.Random (Random(randomR), getStdRandom)
> import "monads-tf" Control.Monad.Error (catchError) -- ick
> import Data.XML.Types (
> 	Content(ContentText),
> 	Element(..),
> 	Name(Name),
> 	Node(NodeContent, NodeElement),
> 	elementText,
> 	isNamed)
> import qualified Data.Map as Map
> import qualified Data.Text as T
> import qualified Database.TokyoCabinet as TC
> import qualified Network.Protocol.XMPP as XMPP

A nice data type for credentials to use connecting to Vitelity.  First Text is DID, second Text is s.ms password.  Derive Eq and Ord so that credentials can be used as keys in the `vitelityManager` Map.  Derive Show and Read as a simple way to serialize this into the database.

> data VitelityCredentials = VitelityCredentials Text Text deriving (Eq, Ord, Show, Read)

This is where our program starts.  When this IO action completes, the program terminates.

> main :: IO ()
> main = do

Force line buffering for our log output, even when redirected to a file.

> 	hSetBuffering stdout LineBuffering
> 	hSetBuffering stderr LineBuffering

First, we need to get our settings from the command line arguments.

> 	(componentJidText, serverHost, serverPort, componentSecret) <- readArgs
> 	let Just componentJid = XMPP.parseJID componentJidText

Open a handle to the Tokyo Cabinet database that we're going to use for storing Vitelity credentials.

> 	db <- openTokyoCabinet "./db.tcdb"

Create a channel that will be used to queue up stanzas for sending out through the component connection.

> 	componentOut <- newTQueueIO
> 	vitelityCommands <- newTQueueIO

Now we connect up the component so that stanzas will be routed to us by the server.
Run in a background thread and reconnect forever if `runComponent` terminates.

> 	void $ forkIO $ forever $ do
> 		log "runComponent" "Starting..."

Catch any exceptions, and log the result on termination, successful or not.

> 		(log "runComponent" <=< (runExceptT . syncIO)) $
> 			XMPP.runComponent
> 			(XMPP.Server componentJid serverHost (PortNumber $ fromIntegral (serverPort :: Int)))
> 			componentSecret
> 			(component db componentOut (writeTQueue vitelityCommands))

Now we start up the service that will manage all our connections to Vitelity and route messages.

> 	vitelityManager (readTQueue vitelityCommands) (mapFromVitelity componentJidText) (writeTQueue componentOut)

This is where we handle talking to the XMPP server.

> component :: TC.HDB -> TQueue StanzaRec -> (VitelityCommand -> STM ()) -> XMPP.XMPP ()
> component db componentOut sendVitelityCommand = do

Loop forever waiting on a channel.  When we get something, log it and send it to the server.  Log exceptions but keep running.

> 	thread <- forkXMPP $ forever $ flip catchError (log "COMPONENT OUT EXCEPTION") $ do
> 		stanza <- liftIO $ atomically $ readTQueue componentOut
> 		log "COMPONENT OUT" stanza
> 		XMPP.putStanza stanza

Loop getting stanzas from the server forever.  If there's an exception, log it and kill the outbound thread as well, then stop.  The caller will restart us.

>	flip catchError (\e -> log "COMPONENT IN EXCEPTION" e >> liftIO (killThread thread)) $ forever $ do
>		stanza <- XMPP.getStanza
>		log "COMPONENT  IN" stanza

Run the action to handle this stanza, and push any reply stanzas to the other thread.

>		mapM (liftIO . atomically . writeTQueue componentOut) =<< liftIO (handleInboundStanza db sendVitelityCommand stanza)

This is a big set of pattern-matches to decide what to do with stanzas we receive from the server.

> handleInboundStanza :: TC.HDB -> (VitelityCommand -> STM ()) -> XMPP.ReceivedStanza -> IO [StanzaRec]

Stanza is a message with both to and from set.

> handleInboundStanza db sendVitelityCommand (XMPP.ReceivedMessage (m@XMPP.Message { XMPP.messageTo = Just to, XMPP.messageFrom = Just from }))

Try to convert the destination JID to a Vitelity JID.  If we succeed, then we have a valid destination to try.

>	| Just vitelityJid <- mapToVitelity to = do

We look up the credentials in the database here so that we can send back an error if there is no registration for the sender.  We also try to extract the body from the message, since if there isn't one we probably don't want to send a blank SMS.

> 		maybeCreds <- fetchVitelityCredentials db from
> 		case (maybeCreds, getBody "jabber:component:accept" m) of
> 			(Nothing, _) -> return [mkStanzaRec $ registrationRequiredError m]
> 			(_, Nothing) -> return [mkStanzaRec $ noBodyError m]

Now that we have the credentials, build the SMS command and send it to Vitelity.

> 			(Just creds, Just body) -> do
> 				atomically $ sendVitelityCommand $
> 					VitelitySMS creds (XMPP.messageID m) vitelityJid body

No stanzas to send back to the sender yet.

> 				return []

JID is not in a format we recognize, so send back a delivery error stanza.

>	| otherwise = do
> 		log "MESSAGE TO INVALID JID" m
> 		return [mkStanzaRec $ invalidJidError m]

If we do not recognize the stanza at all, just print it to the log for now.

> handleInboundStanza _ _ stanza = log "UNKNOWN STANZA" stanza >> return []

This is the error to send back when we get a message to an invalid JID.

> invalidJidError :: XMPP.Message -> XMPP.Message
> invalidJidError = messageError' "cancel" "item-not-found" (s"JID localpart must be in E.164 format.") []

This is the error to send back when we get a message from an unregistered JID.

> registrationRequiredError :: XMPP.Message -> XMPP.Message
> registrationRequiredError = messageError' "auth" "registration-required" (s"You must be registered with Vitelity credentials to use this gateway.") []

This is the error to send back when we get a message with no body.

> noBodyError :: XMPP.Message -> XMPP.Message
> noBodyError = messageError' "modify" "not-acceptable" (s"There was no body on the message you sent.") []

Helper to create an XMPP message error response with basic structure most errors need filled in.

> messageError' :: String -> String -> Text -> [Node] -> XMPP.Message -> XMPP.Message
> messageError' typ definedCondition english morePayload m =
> 	messageError m [
> 		Element (s"{jabber:component:accept}error")
> 		[(s"{jabber:component:accept}type", [ContentText $ fromString typ])]
> 		(
> 			(
> 				NodeElement $ Element (fromString $ "{urn:ietf:params:xml:ns:xmpp-stanzas}" ++ definedCondition) [] []
> 			) :
> 			(
> 				NodeElement $ Element (s"{urn:ietf:params:xml:ns:xmpp-stanzas}text")
> 					[(s"xml:lang", [ContentText $ s"en"])]
> 					[NodeContent $ ContentText english]
> 			) :
> 			morePayload
> 		)
> 	]

Helper to convert a message to its equivalent error return.

> messageError :: XMPP.Message -> [Element] -> XMPP.Message
> messageError m errorPayload = m { 
> 	XMPP.messageType = XMPP.MessageError,

Reverse to and from so that the error goes back to the sender.

> 	XMPP.messageFrom = XMPP.messageTo m,
> 	XMPP.messageTo = XMPP.messageFrom m,

And append the extra error information to the payload.

> 	XMPP.messagePayloads = XMPP.messagePayloads m ++ errorPayload
> }

Check if the JID is one we know how to route.  For now, this means the localpart must follow E.164 and be a NANP number.  If we know how to route it, then return the Vitelity JID to send stanzas to.

> mapToVitelity :: XMPP.JID -> Maybe XMPP.JID
> mapToVitelity (XMPP.JID (Just localpart) _ _)

Valid JIDs have a localpart starting with `+1` and having all other characters as digits.  Strip the `+1` and use as localpart of a JID with domainpart `@sms`.

> 	| Just tel <- T.stripPrefix (s"+1") (XMPP.strNode localpart),
> 	  T.all isDigit tel =
> 		XMPP.parseJID (tel ++ s"@sms")

Everything else is an invalid JID.

> mapToVitelity _ = Nothing

Similarly, we want to map back to E.164 for outgoing stanzas.

> mapFromVitelity :: Text -> XMPP.JID -> Maybe XMPP.JID
> mapFromVitelity hostname (XMPP.JID (Just localpart) _ _)

If there are 10 digits, this is a NANP number, so prefix "+1".

> 	| T.length localpartText == 10 && T.all isDigit localpartText =
> 		XMPP.parseJID (s"+1" ++ localpartText ++ s"@" ++ hostname)

Otherwise, if it starts wih "011" it's an international number, so replace the prefix with "+".

> 	| Just tel <- T.stripPrefix (s"011") localpartText,
> 	  T.all isDigit tel =
> 		XMPP.parseJID (s"+" ++ tel ++ s"@" ++ hostname)
> 	where
> 	localpartText = XMPP.strNode localpart

Everythign else is an invalid JID.

> mapFromVitelity _ _ = Nothing

A management server to keep track of all our connections to Vitelity and route messages to them.

> data VitelityCommand = VitelityRegistration [XMPP.JID] VitelityCredentials | VitelitySMS VitelityCredentials (Maybe Text) XMPP.JID Text
> type VitelityManagerState = Map VitelityCredentials (StanzaRec -> STM (), XMPP.JID -> STM ())

> vitelityManager :: STM VitelityCommand -> (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> IO ()
> vitelityManager getVitelityCommand mapToComponent sendToComponent = go Map.empty
> 	where

This is a forever loop that waits on commands coming in on the `vitelityOut` TChan and handles one at a time using `oneVitelityCommand`.

> 	go vitelitySessions =
> 		atomically getVitelityCommand >>=
> 		oneVitelityCommand mapToComponent sendToComponent vitelitySessions >>=
> 		go

Here we actually handle the `vitelityManager` commands.

> oneVitelityCommand :: (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> VitelityManagerState -> VitelityCommand -> IO VitelityManagerState
> oneVitelityCommand mapToComponent sendToComponent vitelitySessions sms@(VitelitySMS creds@(VitelityCredentials did _) smsID to body)

If we are sending an SMS and a session for those credentials is already connected.

> 	| Just (sendToVitelity, _) <- Map.lookup creds vitelitySessions = do

Format the SMS into an XMPP Stanza and write it to the TChan for the correct session.

> 		atomically $ sendToVitelity $ mkStanzaRec $ (mkSMS to body) { XMPP.messageID = smsID }
> 		return vitelitySessions

Otherwise, we have never connected for this DID.  Highly irregular.  Log this strange situation, try to create the registration, and then retry the SMS.

> 	| otherwise = do
> 		log "oneVitelityCommand" ("No session found for", did)
> 		newSessions <- oneVitelityCommand mapToComponent sendToComponent vitelitySessions (VitelityRegistration [] creds)
> 		oneVitelityCommand mapToComponent sendToComponent newSessions sms

If we are creating a new registration, log that out and then create a session with `vitelitySession` and store the resulting handle in the session Map.

> oneVitelityCommand mapToComponent sendToComponent vitelitySessions (VitelityRegistration jids creds@(VitelityCredentials did _))
> 	| Just (_, addJidSubscription) <- Map.lookup creds vitelitySessions = do
> 		log "oneVitelityCommand" ("New subscription for", jids, did)
> 		atomically $ mapM_ addJidSubscription jids
> 		return vitelitySessions
> 	| otherwise = do
> 		log "oneVitelityCommand" ("New registration for", jids, did)
> 		session@(_, addJidSubscription) <- vitelitySession mapToComponent sendToComponent creds
> 		atomically $ mapM_ addJidSubscription jids
> 		return $! Map.insert creds session vitelitySessions

Here we take some `VitelityCredentials` and actually create the XMPP connection, setting up a bunch of last-ditch exception handling and forever-reconnection logic while we're at it.

> vitelitySession :: (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> VitelityCredentials -> IO (StanzaRec -> STM (), XMPP.JID -> STM ())
> vitelitySession mapToComponent sendToComponent (VitelityCredentials did password) = do
> 	sendStanzas <- newTQueueIO
> 	subscriberJids <- newTVarIO []
> 	void $ forkIO $ forever $
> 		(log "vitelitySession ENDED" <=< (runExceptT . syncIO)) $
> 		(log "vitelitySession ENDED INTERNAL" =<<) $ do
> 			log "vitelitySession" ("Starting", did)
> 			XMPP.runClient smsServer jid did password $ do
> 				void $ XMPP.bindJID jid
> 				vitelityClient (readTQueue sendStanzas) (readTVar subscriberJids) mapToComponent sendToComponent
> 	return (writeTQueue sendStanzas, modifyTVar' subscriberJids . (:))
> 	where
> 	smsServer = XMPP.Server (s"s.ms") "s.ms" (PortNumber 5222)
> 	Just jid = XMPP.parseJID (did ++ s"@s.ms/sgx")

And then finally actually handle the connection the the Vitelity XMPP server.

> vitelityClient :: STM StanzaRec -> STM [XMPP.JID] -> (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> XMPP.XMPP ()
> vitelityClient getNextOutput getSubscriberJids mapToComponent sendToComponent = do

First, set our presence to available.

> 	XMPP.putStanza $ XMPP.emptyPresence XMPP.PresenceAvailable

Then fork a thread to handle outgoing stanzas.  Very similar to the thread for outgoing stanzas on the component connection, but here we wait a random amount of time after each send (because Vitelity kind of sucks and this seems to help reliability).

> 	thread <- forkXMPP $ forever $ flip catchError (liftIO . log "vitelityClient OUT EXCEPTION") $ do
> 		stanza <- liftIO $ atomically getNextOutput
> 		log "VITELITY OUT" stanza
> 		XMPP.putStanza stanza
> 		wait <- liftIO $ getStdRandom (randomR (1000000,2000000))
> 		liftIO $ threadDelay wait

> 	flip catchError (\e -> liftIO (log "vitelityClient IN EXCEPTION" e >> killThread thread)) $ forever $ do
> 		subscribers <- liftIO $ atomically getSubscriberJids
> 		stanza <- XMPP.getStanza
> 		log "VITELITY  IN" stanza
> 		case stanza of
> 			XMPP.ReceivedMessage m
> 				| XMPP.messageType m /= XMPP.MessageError,
> 				  Just from <- mapToComponent =<< XMPP.messageFrom m,
> 				  Just txt <- getBody "jabber:client" m ->
> 					liftIO $ atomically $ mapM_ (\to ->
> 						sendToComponent $ mkStanzaRec ((mkSMS to txt) { XMPP.messageFrom = Just from })
> 					) subscribers

TODO: track who tried to send a particular message and only deliver the error back to them, instead of broadcasting the error to everyone.

At least IDs should line up because we preserve them when sending through to Vitelity.

> 				| XMPP.messageType m == XMPP.MessageError,
> 				  Just from <- mapToComponent =<< XMPP.messageFrom m ->
> 					liftIO $ atomically $ mapM_ (\to ->
> 						sendToComponent $ mkStanzaRec (m { XMPP.messageTo = Just to, XMPP.messageFrom = Just from })
> 					) subscribers
> 			_ -> return ()

Fetch vitelity credentials from the database for a particular source JID.

> fetchVitelityCredentials :: TC.HDB -> XMPP.JID -> IO (Maybe VitelityCredentials)
> fetchVitelityCredentials db from = do

Get whatever is at (or Nothing if the key does not exist) the key corresponding to the bare part of the from JID.

> 	maybeCredentialString <- TC.runTCM (TC.get db $ textToString $ bareTxt from)

Then try to parse the string as VitelityCredentials.

> 	return (readZ =<< maybeCredentialString)

Make the XMPP stanza needed to send an SMS.

> mkSMS :: XMPP.JID -> Text -> XMPP.Message
> mkSMS to txt = (XMPP.emptyMessage XMPP.MessageChat) {
> 	XMPP.messageTo = Just to,
> 	XMPP.messagePayloads = [Element (s"{jabber:client}body") [] [NodeContent $ ContentText txt]]
> }

Helper to get the text representation of the bare part of a JID.

> bareTxt :: XMPP.JID -> Text
> bareTxt (XMPP.JID (Just node) domain _) = mconcat [XMPP.strNode node, s"@", XMPP.strDomain domain]
> bareTxt (XMPP.JID Nothing domain _) = XMPP.strDomain domain

Helper to create a thread in the XMPP context.

> forkXMPP :: XMPP.XMPP () -> XMPP.XMPP ThreadId
> forkXMPP kid = do
> 	session <- XMPP.getSession
> 	liftIO $ forkIO $ void $ XMPP.runXMPP session kid

Helper to extract the body text from an XMPP message.  Takes namespace as a parameter because component vs client streams have a different namespace.

> getBody :: String -> XMPP.Message -> Maybe Text
> getBody ns =
> 	listToMaybe .
> 	fmap (mconcat . elementText) .
> 	(isNamed (Name (s"body") (Just $ fromString ns) Nothing) <=< XMPP.messagePayloads)

Helper for logging that outputs the current time, a tag, and an object.

> log :: (Show a, MonadIO m) => String -> a -> m ()
> log tag x = liftIO $ do
>	time <- getCurrentTime
>	putStr (show time ++ s" " ++ fromString tag ++ s" :: ")
>	print x
>	putStrLn mempty

Alias for fromString to make string literals prettier.

> s :: (IsString a) => String -> a
> s = fromString

A concrete representation of any XMPP Stanza, needed so we can have lists with both Message and IQ stanzas.

> data StanzaRec = StanzaRec (Maybe XMPP.JID) (Maybe XMPP.JID) (Maybe Text) (Maybe Text) [Element] Element deriving (Show)

> instance XMPP.Stanza StanzaRec where
> 	stanzaTo (StanzaRec to _ _ _ _ _) = to
> 	stanzaFrom (StanzaRec _ from _ _ _ _) = from
> 	stanzaID (StanzaRec _ _ sid _ _ _) = sid
> 	stanzaLang (StanzaRec _ _ _ lang _ _) = lang
> 	stanzaPayloads (StanzaRec _ _ _ _ payloads _) = payloads
> 	stanzaToElement (StanzaRec _ _ _ _ _ element) = element

> mkStanzaRec :: (XMPP.Stanza a) => a -> StanzaRec
> mkStanzaRec x = StanzaRec (XMPP.stanzaTo x) (XMPP.stanzaFrom x) (XMPP.stanzaID x) (XMPP.stanzaLang x) (XMPP.stanzaPayloads x) (XMPP.stanzaToElement x)

> openTokyoCabinet :: (TC.TCDB a) => String -> IO a
> openTokyoCabinet pth = TC.runTCM $ do
> 	db <- TC.new
> 	True <- TC.open db pth [TC.OREADER, TC.OWRITER, TC.OCREAT]
> 	return db
