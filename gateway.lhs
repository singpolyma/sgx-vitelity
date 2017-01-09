We need this language extension because the "monads-tf" package uses an already used module name, unfortunately.

> {-# LANGUAGE PackageImports #-}

Only exporting the main function allows GHC to do more optimisations inside, and lets -Wall warn you about unused code more effectively.

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
> 	elementChildren,
> 	elementText,
> 	isNamed)
> import qualified Data.Map as Map
> import qualified Data.Text as T
> import qualified Database.TokyoCabinet as TC
> import qualified Network.Protocol.XMPP as XMPP

A nice data type for credentials to use when connecting to Vitelity.  First Text is DID, second Text is s.ms password.  Derive Eq and Ord so that credentials can be used as keys in the `vitelityManager` Map.  Derive Show and Read as a simple way to serialize this into the database.

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

Create the channels that will be used for sending stanzas out of the component, and also sending commands to the vitelityManager.

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

This is where we handle talking to the XMPP server as an external component.  After the connection is created above, it delegates control of that connection here.

> component :: TC.HDB -> TQueue StanzaRec -> (VitelityCommand -> STM ()) -> XMPP.XMPP ()
> component db componentOut sendVitelityCommand = do

This chunk of code owns the outbound portion of our external component connection.  Anyone who wants to send a stanza as us will need to get their stanza into the channel that we read from here.  This is a thread that loops forever, blocking on the channel and sending everything that gets put into the channel out over our component connection to the XMPP server.  Any exceptions are logged, but otherwise ignored.

> 	thread <- forkXMPP $ forever $ flip catchError (log "COMPONENT OUT EXCEPTION") $ do
> 		stanza <- liftIO $ atomically $ readTQueue componentOut
> 		log "COMPONENT OUT" stanza
> 		XMPP.putStanza stanza

And now for inbound stanzas from the XMPP server.  Again, loop forever, but we treat any exceptions here as fatal.  The idea is that if the component connection really has gone down, then both the outbound thread above as well as this code will begin to fail, so we only need to treat one set of exceptions as fatal.  Log the fatal exception and also kill the outbound thread.  The caller will reconnect to the XMPP server and then hand control back to us.

>	flip catchError (\e -> log "COMPONENT IN EXCEPTION" e >> liftIO (killThread thread)) $ forever $ do
>		stanza <- XMPP.getStanza
>		log "COMPONENT  IN" stanza

Once we get a stanza from the server, run the action to handle this stanza, and push any reply stanzas to the other thread.

>		mapM (liftIO . atomically . writeTQueue componentOut) =<< liftIO (handleInboundStanza db sendVitelityCommand stanza)

How to handle the incoming stanzas is decieded by a big set of pattern-matches.

> handleInboundStanza :: TC.HDB -> (VitelityCommand -> STM ()) -> XMPP.ReceivedStanza -> IO [StanzaRec]

If we match a stanza that is a message with both to and from set.

> handleInboundStanza db sendVitelityCommand (XMPP.ReceivedMessage (m@XMPP.Message { XMPP.messageTo = Just to, XMPP.messageFrom = Just from }))

Try to convert the destination JID to a Vitelity JID.  If we succeed, then we have a valid destination to try.

>	| Just vitelityJid <- mapToVitelity to = do

We look up the credentials in the database here so that we can send back an error if there is no registration for the sender.  We also try to extract the body from the message, since if there isn't one we probably don't want to send a blank SMS.

> 		maybeCreds <- fetchVitelityCredentials db from
> 		case (maybeCreds, getBody "jabber:component:accept" m) of
> 			(Nothing, _) -> return [mkStanzaRec $ registrationRequiredError m]

If the message is an error, we don't actually care about the body.  Send an SMS about the error.

> 			(Just creds, _)
> 				| XMPP.messageType m == XMPP.MessageError ->

Extract the first human-readable error message we run across, if there are any.

> 					let
> 						errorTxt = fmap (mconcat . elementText) $ listToMaybe $
> 							isNamed (fromString "{urn:ietf:params:xml:ns:xmpp-stanzas}text") =<<
> 							elementChildren =<< isNamed (fromString "{jabber:component:accept}error") =<<
> 							XMPP.messagePayloads m
> 					in do

And send an SMS about the error, including the message we found if there was one.
No stanzas to send back to the sender at this point, so send back and empty list.

> 						atomically $ sendVitelityCommand $
> 							VitelitySMS creds (XMPP.messageID m) vitelityJid
> 								(s"Error sending message" ++ maybe mempty ((s": ")++) errorTxt)
> 						return []

If it's not an error, then not having a body is a problem and we return an error ourselves.

> 			(_, Nothing) -> return [mkStanzaRec $ noBodyError m]

Now that we have the credentials and the body, build the SMS command and send it to Vitelity.
No stanzas to send back to the sender at this point, so send back and empty list.

> 			(Just creds, Just body) -> do
> 				atomically $ sendVitelityCommand $
> 					VitelitySMS creds (XMPP.messageID m) vitelityJid body
> 				return []

If we fail to convert the destination to a Vitelity JID, send back and delivery error stanza.

>	| otherwise = do
> 		log "MESSAGE TO INVALID JID" m
> 		return [mkStanzaRec $ invalidJidError m]

If we do not recognize the stanza at all, just print it to the log for now.

> handleInboundStanza _ _ stanza = log "UNKNOWN STANZA" stanza >> return []

This is the code that tries to convert destinations to Vitelity JIDs.  For now, this means the localpart must follow E.164 and be a NANP number.  If we know how to route it, then return the Vitelity JID to send stanzas to.

> mapToVitelity :: XMPP.JID -> Maybe XMPP.JID
> mapToVitelity (XMPP.JID (Just localpart) _ _)

Valid JIDs have a localpart starting with `+1` and having all other characters as digits.  Strip the `+1` and use as localpart of a JID with domainpart `@sms`.

> 	| Just tel <- T.stripPrefix (s"+1") (XMPP.strNode localpart),
> 	  T.all isDigit tel =
> 		XMPP.parseJID (tel ++ s"@sms")

Everything else is an invalid JID.

> mapToVitelity _ = Nothing

Similarly, we will want a way to map back to E.164 for outgoing stanzas.

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

Now we define a management server to keep track of all our connections to Vitelity and route messages to them.

The vitelityManager takes commands from other threads using this datatype.

> data VitelityCommand =

The most obvious command is one to send an SMS.  We'll need the relevant credentials, maybe a stanza ID (so that errors can come back with the same ID), the destination JID, and the body of the SMS.

> 	VitelitySMS VitelityCredentials (Maybe Text) XMPP.JID Text |

We also need a way to tell the manager where to route incoming SMSs from a given connection to Vitelity.

> 	VitelityRegistration [XMPP.JID] VitelityCredentials

We also define a simple type synonym for the Map that holds our active connections to Vitelity.  The credentials act as the key into the Map, and for each key we store two actions: one to send a stanza out, and one to add a JID to the list of subscribers that get incoming SMSs.

> type VitelityManagerState = Map VitelityCredentials (StanzaRec -> STM (), XMPP.JID -> STM ())

The manager itself is a forever recursion that waits on commands coming in and handles one at a time using `oneVitelityCommand`.  The result of `oneVitelityCommand` becomes the new Map for the next iteration.

> vitelityManager :: STM VitelityCommand -> (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> IO ()
> vitelityManager getVitelityCommand mapToComponent sendToComponent = go Map.empty
> 	where
> 	go vitelitySessions =
> 		atomically getVitelityCommand >>=
> 		oneVitelityCommand mapToComponent sendToComponent vitelitySessions >>=
> 		go

Here we actually handle the `vitelityManager` commands.

> oneVitelityCommand :: (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> VitelityManagerState -> VitelityCommand -> IO VitelityManagerState
> oneVitelityCommand mapToComponent sendToComponent vitelitySessions sms@(VitelitySMS creds@(VitelityCredentials did _) smsID to body)

If we are sending an SMS and a session for those credentials is already connected, format the SMS into an XMPP Stanza and write it to the correct session.  No change to the sessions map, so just return the one we have.

> 	| Just (sendToVitelity, _) <- Map.lookup creds vitelitySessions = do
> 		atomically $ sendToVitelity $ mkStanzaRec $ (mkSMS to body) { XMPP.messageID = smsID }
> 		return vitelitySessions

Otherwise, we have never connected for this DID.  Highly irregular.  Log this strange situation, try to create the registration, and then retry the SMS.

> 	| otherwise = do
> 		log "oneVitelityCommand" ("No session found for", did)
> 		newSessions <- oneVitelityCommand mapToComponent sendToComponent vitelitySessions (VitelityRegistration [] creds)
> 		oneVitelityCommand mapToComponent sendToComponent newSessions sms

When asked to create a registration, first check if we already have an active session for these credentials (could happen if multiple remote JIDs are all registered through the same Vitelity DID).  If so, just add new subscribers to that session.

> oneVitelityCommand mapToComponent sendToComponent vitelitySessions (VitelityRegistration jids creds@(VitelityCredentials did _))
> 	| Just (_, addJidSubscription) <- Map.lookup creds vitelitySessions = do
> 		log "oneVitelityCommand" ("New subscription for", jids, did)
> 		atomically $ mapM_ addJidSubscription jids
> 		return vitelitySessions

Otherwise, we need to actually start up a new session.  Then add the subscribers, and return a new Map with the new session inserted.

> 	| otherwise = do
> 		log "oneVitelityCommand" ("New registration for", jids, did)
> 		session@(_, addJidSubscription) <- vitelitySession mapToComponent sendToComponent creds
> 		atomically $ mapM_ addJidSubscription jids
> 		return $! Map.insert creds session vitelitySessions

Here we take some `VitelityCredentials` and actually create the XMPP connection, setting up a bunch of last-ditch exception handling and forever-reconnection logic while we're at it.

> vitelitySession :: (XMPP.JID -> Maybe XMPP.JID) -> (StanzaRec -> STM ()) -> VitelityCredentials -> IO (StanzaRec -> STM (), XMPP.JID -> STM ())
> vitelitySession mapToComponent sendToComponent (VitelityCredentials did password) = do

The outbound stanza channel is similar to what we used before for the component.  Subscriber JIDs are just stored in a threadsafe mutable variable for now.

> 	sendStanzas <- newTQueueIO
> 	subscriberJids <- newTVarIO []

You know the drill.  Loop forever in case the connection dies, catch an log any exceptions.  Connect to the server and then delegate responsability for the connection to a hanlder.

> 	void $ forkIO $ forever $
> 		(log "vitelitySession ENDED" <=< (runExceptT . syncIO)) $
> 		(log "vitelitySession ENDED INTERNAL" =<<) $ do
> 			log "vitelitySession" ("Starting", did)
> 			XMPP.runClient smsServer jid did password $ do
> 				void $ XMPP.bindJID jid
> 				vitelityClient (readTQueue sendStanzas) (readTVar subscriberJids) mapToComponent sendToComponent

The caller doesn't need to know about our internals, just pass back usable actions to allow adding to the stanza channel and the subscriber list.

> 	return (writeTQueue sendStanzas, modifyTVar' subscriberJids . (:))
> 	where

We can hard-code the server to connect to, since we know it's Vitelity's s.ms.

> 	smsServer = XMPP.Server (s"s.ms") "s.ms" (PortNumber 5222)

And also the server and resource to go along with the given DID to produce the login JID.

> 	Just jid = XMPP.parseJID (did ++ s"@s.ms/sgx")

Once a particular connection to Vitelity has been established, control is trasferred here.

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

Inbound loop is very similar too, considering exceptions fatal and killing the outbound thread.  The pattern matches for how to handle inbound stanzas are inline for now because there are a lot fewer stanzas that we expect from Vitelity.  Mostly just messages.

> 	flip catchError (\e -> liftIO (log "vitelityClient IN EXCEPTION" e >> killThread thread)) $ forever $ do
> 		subscribers <- liftIO $ atomically getSubscriberJids
> 		stanza <- XMPP.getStanza
> 		log "VITELITY  IN" stanza
> 		case stanza of
> 			XMPP.ReceivedMessage m

If the stanza is a message error, basically just pass it through the gateway to the originator.  Well, it should be to the originator, but we don't store anything that would let us determine that.  So we send the error to every subscriber for now.  The ID should match the original message (because we copied the inbound IDs onto our outbound stanzas to Vitelity, remember?) so we just need to change the from and to according to what subscribers expect.

> 				| XMPP.messageType m == XMPP.MessageError,
> 				  Just from <- mapToComponent =<< XMPP.messageFrom m ->
> 					liftIO $ atomically $ mapM_ (\to ->
> 						sendToComponent $ mkStanzaRec (m { XMPP.messageTo = Just to, XMPP.messageFrom = Just from })
> 					) subscribers

Other messages are inbound SMS.  Make sure we can map the source to a JID in the expected format, and that there's a usable message body.  Then send the message out to all subscribers to this DID.

> 				| Just from <- mapToComponent =<< XMPP.messageFrom m,
> 				  Just txt <- getBody "jabber:client" m ->
> 					liftIO $ atomically $ mapM_ (\to ->
> 						sendToComponent $ mkStanzaRec ((mkSMS to txt) { XMPP.messageFrom = Just from })
> 					) subscribers

Otherwise Vitelity is just sending us some other thing we don't care about (like presence or something).  Ignore it for now.

> 			_ -> return ()

And that's it!  Of course, there's some more little helpers we should build to make the above work out.

We need a way to fetch vitelity credentials from the database for a particular source JID.

> fetchVitelityCredentials :: TC.HDB -> XMPP.JID -> IO (Maybe VitelityCredentials)
> fetchVitelityCredentials db from = do

Get whatever is at (or Nothing if the key does not exist) the key corresponding to the bare part of the from JID.

> 	maybeCredentialString <- TC.runTCM (TC.get db $ textToString $ bareTxt from)

Then try to parse the string as VitelityCredentials.

> 	return (readZ =<< maybeCredentialString)

We also want a way to format the XMPP stanzas we use to send SMS (both to Vitelity, and from Vitelity to subscribers).

> mkSMS :: XMPP.JID -> Text -> XMPP.Message
> mkSMS to txt = (XMPP.emptyMessage XMPP.MessageChat) {
> 	XMPP.messageTo = Just to,
> 	XMPP.messagePayloads = [Element (s"{jabber:client}body") [] [NodeContent $ ContentText txt]]
> }

Here is a way to get the Text representation of the bare part of a JID.

> bareTxt :: XMPP.JID -> Text
> bareTxt (XMPP.JID (Just node) domain _) = mconcat [XMPP.strNode node, s"@", XMPP.strDomain domain]
> bareTxt (XMPP.JID Nothing domain _) = XMPP.strDomain domain

The XMPP connections run in their own special context, so if we want to fork threads inside there (which we do in both cases above), we use this handy helper.

> forkXMPP :: XMPP.XMPP () -> XMPP.XMPP ThreadId
> forkXMPP kid = do
> 	session <- XMPP.getSession
> 	liftIO $ forkIO $ void $ XMPP.runXMPP session kid

Here we extract the body text from an XMPP message.  Takes namespace as a parameter because component vs client streams have a different namespace.

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

The XMPP library we're using has Stanza as a typeclass and everything polymorphic.  That's nice, but I want to put stanzas into data structures, and so I have to pick a concrete type.  This cute setup allows for a generic implementation of the typeclass for any stanza, not just particular ones, and can convert from anything implementing the typeclass.  So we can make all our various different types look the same, and then they can live together in a channel or list.  We lose some type information, but by the time a stanza is going into a channel it's about to go out onto the wire anyway, so we don't care too much.

> data StanzaRec = StanzaRec (Maybe XMPP.JID) (Maybe XMPP.JID) (Maybe Text) (Maybe Text) [Element] Element deriving (Show)

> mkStanzaRec :: (XMPP.Stanza a) => a -> StanzaRec
> mkStanzaRec x = StanzaRec (XMPP.stanzaTo x) (XMPP.stanzaFrom x) (XMPP.stanzaID x) (XMPP.stanzaLang x) (XMPP.stanzaPayloads x) (XMPP.stanzaToElement x)

> instance XMPP.Stanza StanzaRec where
> 	stanzaTo (StanzaRec to _ _ _ _ _) = to
> 	stanzaFrom (StanzaRec _ from _ _ _ _) = from
> 	stanzaID (StanzaRec _ _ sid _ _ _) = sid
> 	stanzaLang (StanzaRec _ _ _ lang _ _) = lang
> 	stanzaPayloads (StanzaRec _ _ _ _ payloads _) = payloads
> 	stanzaToElement (StanzaRec _ _ _ _ _ element) = element

It takes two lines to open a Tokyo Cabinet with the bindings we're using.  Too many lines!  Wrap it in a function.

> openTokyoCabinet :: (TC.TCDB a) => String -> IO a
> openTokyoCabinet pth = TC.runTCM $ do
> 	db <- TC.new
> 	True <- TC.open db pth [TC.OREADER, TC.OWRITER, TC.OCREAT]
> 	return db

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
