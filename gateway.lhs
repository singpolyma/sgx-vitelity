We need this language extension because the "monads-tf" package uses an already used module name, unfortunately.

> {-# LANGUAGE PackageImports #-}

Only exporting the main function allows GHC to do more optimisations inside, and lets -Wall warn you about unused code more effectively.

> module Main (main) where

Switch to BasicPrelude because it's nice.

> import Prelude ()
> import qualified Prelude
> import BasicPrelude hiding (log, forM_)

Import all the things!

> import Data.Char
> import Control.Concurrent
> import Control.Concurrent.STM
> import Data.Foldable (forM_)
> import Data.Time (getCurrentTime)
> import Control.Error (exceptT, fmapLT, runExceptT, syncIO, readZ, ExceptT, hoistEither)
> import UnexceptionalIO (Unexceptional)
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

Some constants for our name and version.

> softwareName :: Text
> softwareName = s"Soprani.ca Gateway to XMPP - Vitelity"

> softwareVersion :: Text
> softwareVersion = s"0.1.0"

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

Create the channels that will be used for sending stanzas out of the component, and also sending commands to the vitelityManager.

> 	componentOut <- newTQueueIO
> 	vitelityCommands <- newTQueueIO

Open a handle to the Tokyo Cabinet database that we're going to use for storing Vitelity credentials.

> 	db <- openTokyoCabinet "./db.tcdb"

Then, get the list of keys for registration records in the database, loop over each and remove the "registration\0" prefix to get the JID.  Enqueue the JID and the credentials to be handled by the vitelityManager once it is running.

> 	registrationKeys <- TC.runTCM $ TC.fwmkeys db "registration\0" maxBound
> 	forM_ (registrationKeys :: [String]) $ \key -> do
> 		maybeCredString <- TC.runTCM (TC.get db key)
> 		forM_ (readZ =<< maybeCredString) $ \creds ->
> 			forM_ (XMPP.parseJID =<< T.stripPrefix (s"registration\0") (fromString key)) $ \jid ->
> 				atomically $ writeTQueue vitelityCommands $ VitelityRegistration [jid] creds

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

If there are no credentials, then we either send back an error or (if the message itself is an error) do nothing (to prevent error-reply-to-error infinite loops).

> 			(Nothing, _) | XMPP.messageType m == XMPP.MessageError -> return []
> 			(Nothing, _) -> return [mkStanzaRec $ messageError registrationRequiredError m]

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
> 							VitelitySMS creds (SMSID <$> XMPP.messageID m <*> pure from) vitelityJid
> 								(s"Error sending message" ++ maybe mempty (s": " ++) errorTxt)
> 						return []

If it's not an error, then not having a body is a problem and we return an error ourselves.

> 			(_, Nothing) -> return [mkStanzaRec $ messageError noBodyError m]

Now that we have the credentials and the body, build the SMS command and send it to Vitelity.
No stanzas to send back to the sender at this point, so send back and empty list.

> 			(Just creds, Just body) -> do
> 				atomically $ sendVitelityCommand $
> 					VitelitySMS creds (SMSID <$> XMPP.messageID m <*> pure from) vitelityJid body
> 				return []

If we fail to convert the destination to a Vitelity JID, send back and delivery error stanza.

>	| otherwise = do
> 		log "MESSAGE TO INVALID JID" m
> 		return [mkStanzaRec $ messageError invalidJidError m]

The XMPP server will send us presence stanzas of type "probe" when someone wants to know the presence of one of our JIDs.

> handleInboundStanza _ _ (XMPP.ReceivedPresence p@(XMPP.Presence {
> 	XMPP.presenceType = XMPP.PresenceProbe,
> 	XMPP.presenceFrom = Just from,
> 	XMPP.presenceTo = Just to
> }))

If there is no localpart, then they are asking for presence of the gateway itself.  The gateway is always available, and includes XEP-0115 information to help improve service discovery efficiency.

> 	| Nothing <- XMPP.jidNode to =
> 		return [mkStanzaRec $ (XMPP.emptyPresence XMPP.PresenceAvailable) {
> 			XMPP.presenceTo = Just from,
> 			XMPP.presenceFrom = Just to,
> 			XMPP.presencePayloads = [
> 				Element (s"{http://jabber.org/protocol/caps}c") [
> 					(s"{http://jabber.org/protocol/caps}hash", [ContentText $ s"sha-1"]),
> 					(s"{http://jabber.org/protocol/caps}node", [ContentText $ s"xmpp:vitelity.soprani.ca"]),
> 					-- gateway/sms//Soprani.ca Gateway to XMPP - Vitelity<jabber:iq:register<jabber:iq:version<vcard-temp<
> 					(s"{http://jabber.org/protocol/caps}ver", [ContentText $ s"fM5iv/aMLmSbJBivCilUAI0MUFY="])
> 				] []
> 			]
> 		}]

If there is a valid localpart, then we might as well claim numbers are available.

> 	| Just _ <- mapToVitelity to =
> 		return [mkStanzaRec $ (XMPP.emptyPresence XMPP.PresenceAvailable) {
> 			XMPP.presenceTo = Just from,
> 			XMPP.presenceFrom = Just to,
> 			XMPP.presencePayloads = [
> 				Element (s"{http://jabber.org/protocol/caps}c") [
> 					(s"{http://jabber.org/protocol/caps}hash", [ContentText $ s"sha-1"]),
> 					(s"{http://jabber.org/protocol/caps}node", [ContentText $ s"xmpp:vitelity.soprani.ca/sgx"]),
> 					-- client/sms//Soprani.ca Gateway to XMPP - Vitelity<jabber:iq:version<
> 					(s"{http://jabber.org/protocol/caps}ver", [ContentText $ s"Xyjv2vDeRUglY9xigEbdkBIkPSE="])
> 				] []
> 			]
> 		}]

Everything else is an invalid JID, so return an error.

>	| otherwise = do
> 		log "PRESENCE TO INVALID JID" p
> 		return [mkStanzaRec $ presenceError invalidJidError p]

Auto-approve presence subscription requests sent to the gateway itself, and also reciprocate (we want to know when gateway users come online).

> handleInboundStanza _ _ (XMPP.ReceivedPresence p@(XMPP.Presence {
> 	XMPP.presenceType = XMPP.PresenceSubscribe,
> 	XMPP.presenceFrom = Just from,
> 	XMPP.presenceTo = Just to
> }))
> 	| Nothing <- XMPP.jidNode to = do
> 		log "handleInboundStanza PresenceSubscribe" (from, to)
> 		return [
> 				mkStanzaRec $ (XMPP.emptyPresence XMPP.PresenceSubscribed) {
> 					XMPP.presenceTo = Just from,
> 					XMPP.presenceFrom = Just to
> 				},
> 				mkStanzaRec $ (XMPP.emptyPresence XMPP.PresenceSubscribe) {
> 					XMPP.presenceTo = Just from,
> 					XMPP.presenceFrom = Just to
> 				}
> 			]

Auto-approve presence subscription requests sent to valid phone numbers.

> 	| Just _ <- mapToVitelity to = do
> 		log "handleInboundStanza PresenceSubscribe" (from, to)
> 		return [
> 				mkStanzaRec $ (XMPP.emptyPresence XMPP.PresenceSubscribed) {
> 					XMPP.presenceTo = Just from,
> 					XMPP.presenceFrom = Just to
> 				}
> 			]

Everything else is an invalid JID, so return an error.

>	| otherwise = do
> 		log "PRESENCE TO INVALID JID" p
> 		return [mkStanzaRec $ presenceError invalidJidError p]

If we match an iq "get" requesting the registration form, then deliver back the form in XEP-0077 format.

> handleInboundStanza _ _ (XMPP.ReceivedIQ iq@(XMPP.IQ {
> 	XMPP.iqType = XMPP.IQGet,
> 	XMPP.iqFrom = Just from,
> 	XMPP.iqTo = Just to@(XMPP.JID { XMPP.jidNode = Nothing }),
> 	XMPP.iqPayload = Just p
> }))
> 	| [_] <- isNamed (s"{jabber:iq:register}query") p =
> 		return [mkStanzaRec $ iq {
> 			XMPP.iqTo = Just from,
> 			XMPP.iqFrom = Just to,
> 			XMPP.iqType = XMPP.IQResult,
> 			XMPP.iqPayload = Just $ Element (s"{jabber:iq:register}query") []
> 				[
> 					NodeElement $ Element (s"{jabber:iq:register}instructions") [] [
> 						NodeContent $ ContentText $ s"Please enter your DID and the password you set for Vitelity's s.ms service."
> 					],
> 					NodeElement $ Element (s"{jabber:iq:register}phone") [] [],
> 					NodeElement $ Element (s"{jabber:iq:register}password") [] []
>				]
>		}]

If we match an iq "set" with a completed registration form, then register the user.

> handleInboundStanza db sendVitelityCommand (XMPP.ReceivedIQ iq@(XMPP.IQ {
> 	XMPP.iqType = XMPP.IQSet,
> 	XMPP.iqFrom = Just from,
> 	XMPP.iqTo = Just (XMPP.JID { XMPP.jidNode = Nothing }),
> 	XMPP.iqPayload = Just p
> }))
> 	| [query] <- isNamed (s"{jabber:iq:register}query") p =

Extract the values from the completed form.

> 		let
> 			phone = mconcat . elementText <$> listToMaybe
> 				(isNamed (s"{jabber:iq:register}phone") =<< elementChildren query)
> 			password = mconcat . elementText <$> listToMaybe
> 				(isNamed (s"{jabber:iq:register}password") =<< elementChildren query)

Try to normalize the phone number.  After all, a human typed it in.

> 		in case (normalizeTel =<< phone, password) of

If we get a working E.164 number and possible password, then we can actually try the registration.

> 			(Just tel, Just pw) -> do
> 				let creds = VitelityCredentials tel pw

Try to connect to Vitelity with the credentials, and check if they work.  Return a not-authorized error on failure.

> 				connectSuccess <- exceptT (const $ return False) (const $ return True) (vitelityConnect creds (return ()))
> 				if not connectSuccess then
> 					return [mkStanzaRec $ iqError vitelityAuthError iq]
> 				else do

Store the credentials in the database.

> 					True <- TC.runTCM $ TC.put db ("registration\0" ++ textToString (bareTxt from)) (textToString $ show creds)

Send the registration over to the vitelityManager.

> 					atomically $ sendVitelityCommand $ VitelityRegistration [from] creds

And return a sucess result to the user.

> 					return [mkStanzaRec $ iqReply Nothing iq]

Otherwise, the user has made a serious mistake, and we will have to return an error.

> 			_ -> return [mkStanzaRec $ iqError badRegistrationInfoError iq]

Match when the inbound stanza is an IQ of type get, with a proper from, to, and some kind of payload.

> handleInboundStanza _ _ (XMPP.ReceivedIQ iq@(XMPP.IQ {
> 	XMPP.iqType = XMPP.IQGet,
> 	XMPP.iqFrom = Just from,
> 	XMPP.iqTo = Just to,
> 	XMPP.iqPayload = Just p
> }))

If the IQ was send to a JID with no localpart, then the query is for the gateway itself.  So if the request is service discovery on the gateway, log the request and return our XEP-0030 info.

> 	| Nothing <- XMPP.jidNode to,
> 	  [_] <- isNamed (s"{http://jabber.org/protocol/disco#info}query") p = do
> 		log "DISCO ON US" (from, to, p)
> 		return [mkStanzaRec $ (`iqReply` iq) $ Just $
> 				Element (s"{http://jabber.org/protocol/disco#info}query") []
> 				[
> 					NodeElement $ Element (s"{http://jabber.org/protocol/disco#info}identity") [
> 						(s"{http://jabber.org/protocol/disco#info}category", [ContentText $ s"gateway"]),
> 						(s"{http://jabber.org/protocol/disco#info}type", [ContentText $ s"sms"]),
> 						(s"{http://jabber.org/protocol/disco#info}name", [ContentText softwareName])
> 					] [],
> 					NodeElement $ Element (s"{http://jabber.org/protocol/disco#info}feature") [
> 						(s"{http://jabber.org/protocol/disco#info}var", [ContentText $ s"jabber:iq:register"]),
> 						(s"{http://jabber.org/protocol/disco#info}var", [ContentText $ s"jabber:iq:version"]),
> 						(s"{http://jabber.org/protocol/disco#info}var", [ContentText $ s"vcard-temp"])
> 					] []
> 				]
> 			]

XEP-0030 info queries sent to a valid JID respond with the capabilities nodes have.

> 	| Just _ <- mapToVitelity to,
> 	  [_] <- isNamed (s"{http://jabber.org/protocol/disco#info}query") p = do
> 		log "DISCO ON NODE" (from, to, p)
> 		return [mkStanzaRec $ (`iqReply` iq) $ Just $
> 				Element (s"{http://jabber.org/protocol/disco#info}query") []
> 				[
> 					NodeElement $ Element (s"{http://jabber.org/protocol/disco#info}identity") [
> 						(s"{http://jabber.org/protocol/disco#info}category", [ContentText $ s"client"]),
> 						(s"{http://jabber.org/protocol/disco#info}type", [ContentText $ s"sms"]),
> 						(s"{http://jabber.org/protocol/disco#info}name", [ContentText softwareName])
> 					] [],
> 					NodeElement $ Element (s"{http://jabber.org/protocol/disco#info}feature") [
> 						(s"{http://jabber.org/protocol/disco#info}var", [ContentText $ s"jabber:iq:version"])
> 					] []
> 				]
> 			]

If the IQ was send to a JID with no localpart, then the query is for the gateway itself.  So if the request is for the vCard of the gateway, return according to XEP-0054.

> 	| Nothing <- XMPP.jidNode to,
> 	  [_] <- isNamed (s"{vcard-temp}vCard") p =
> 		return [mkStanzaRec $ (`iqReply` iq) $ Just $
> 			Element (s"{vcard-temp}vCard") []
> 			[
> 				NodeElement $ Element (s"{vcard-temp}URL") [] [NodeContent $ ContentText $ s"https://github.com/singpolyma/sgx-vitelity"],
> 				NodeElement $ Element (s"{vcard-temp}DESC") [] [NodeContent $ ContentText $ s"This is an XMPP-to-SMS gateway using vitelity.com as the backend. © Stephen Paul Weber, licensed under AGPLv3+.\n\nSource code for this gateway is available from the listed homepage.\n\nPart of the Soprani.ca project."]
> 			]
> 		]

If someone asks us what our software version is, we tell them

> 	| [_] <- isNamed (s"{jabber:iq:version}query") p =
> 		return [mkStanzaRec $ (`iqReply` iq) $ Just $
> 			Element (s"{jabber:iq:version}query") []
> 			[
> 				NodeElement $ Element (s"{jabber:iq:version}name") [] [NodeContent $ ContentText softwareName],
> 				NodeElement $ Element (s"{jabber:iq:version}version") [] [NodeContent $ ContentText softwareVersion]
> 			]
> 		]

Un-handled IQ requests should be at least replied to with an error.  It's the polite thing to do.

> handleInboundStanza _ _ (XMPP.ReceivedIQ iq@(XMPP.IQ { XMPP.iqType = typ }))
> 	| typ `elem` [XMPP.IQGet, XMPP.IQSet] =
> 		return [mkStanzaRec $ iqError (errorPayload "cancel" "feature-not-implemented" mempty []) iq]

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

Everything else is an invalid JID.

> mapFromVitelity _ _ = Nothing

Sometimes we want to be more forgiving, such as when we're taking a user registration.  So we need to take garbage a human might type and turn it into E.164 if we can.

> normalizeTel :: Text -> Maybe Text
> normalizeTel inputString

If there are 10 digits, add the "+1" prefix.

> 	| T.length tel == 10 = Just (s"+1" ++ tel)

If there are 11 digits, then check if the first one is a "1".  If so, we just need to prefix the "+".

> 	| T.length tel == 11, s"1" `T.isPrefixOf` tel = Just (T.cons '+' tel)

Everything else is unusable.

> 	| otherwise = Nothing

But we want to be nice, so let's remove any non-digits before we make the above checks, so that seperators, etc, won't break us.

> 	where
> 	tel = T.filter isDigit inputString

Now we define a management server to keep track of all our connections to Vitelity and route messages to them.

The vitelityManager takes commands from other threads using this datatype.

> data VitelityCommand =

The most obvious command is one to send an SMS.  We'll need the relevant credentials, maybe a stanza ID and component-side source JID (so that errors can be sent back), the destination JID, and the body of the SMS.

> 	VitelitySMS VitelityCredentials (Maybe SMSID) XMPP.JID Text |

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
> 		atomically $ sendToVitelity $ mkStanzaRec $ (mkSMS "jabber:client" to body) { XMPP.messageID = show <$> smsID }
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
> vitelitySession mapToComponent sendToComponent creds@(VitelityCredentials did _) = do

The outbound stanza channel is similar to what we used before for the component.  Subscriber JIDs are just stored in a threadsafe mutable variable for now.

> 	sendStanzas <- newTQueueIO
> 	subscriberJids <- newTVarIO []

Loop forever in case the connection dies, log any result.  Connect to the server and then delegate responsability for the connection to a hanlder.

> 	void $ forkIO $ forever $ do
> 		log "vitelitySession" ("Starting", did)
> 		result <- runExceptT $ vitelityConnect creds
> 			(vitelityClient (readTQueue sendStanzas) (readTVar subscriberJids) mapToComponent sendToComponent)
> 		case result of

In the case of authentication failure, send a headline to all subscribers telling them authentication has failed.  Then just eat any messages they try to send and reply with the auth error.

> 			Left (XMPP.AuthenticationFailure _) -> do
> 				subscribers <- atomically $ readTVar subscriberJids
> 				atomically $ forM_ subscribers $ \to ->
> 					sendToComponent $ mkStanzaRec ((mkSMS "jabber:component:accept" to vitelityAuthErrorMsg) {
> 						XMPP.messageType = XMPP.MessageHeadline
> 					})
> 				forever $ do
> 					attemptedStanza <- atomically $ readTQueue sendStanzas
> 					let smsID = readZ =<< fmap textToString (XMPP.stanzaID attemptedStanza)
> 					atomically $ sendToComponent $ mkStanzaRec $ messageError vitelityAuthError ((XMPP.emptyMessage XMPP.MessageError) {
> 							XMPP.messageID = fmap smsidID smsID,
> 							XMPP.messageTo = mapToComponent =<< XMPP.stanzaTo attemptedStanza,
> 							XMPP.messageFrom = fmap smsidFrom smsID,
> 							XMPP.messagePayloads = XMPP.stanzaPayloads attemptedStanza
> 						})
> 			_ -> log "vitelitySession" ("Ended", result)

The caller doesn't need to know about our internals, just pass back usable actions to allow adding to the stanza channel and the subscriber list.

> 	return (writeTQueue sendStanzas, modifyTVar' subscriberJids . (:))

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

If the stanza is a message error, basically just pass it through the gateway to the originator.  We encoded the originator into the id when we sent the message, so it is included here in any error reply.  We can parse the ID to get back the original message id and originator JID to send the error back to.

> 				| XMPP.messageType m == XMPP.MessageError,
> 				  Just from <- mapToComponent =<< XMPP.messageFrom m ->
> 					let smsID = readZ =<< fmap textToString (XMPP.messageID m) in
> 					liftIO $ atomically $ sendToComponent $ mkStanzaRec (m {
> 						XMPP.messageID = fmap smsidID smsID,
> 						XMPP.messageTo = fmap smsidFrom smsID,
> 						XMPP.messageFrom = Just from
> 					})

Other messages are inbound SMS.  Make sure we can map the source to a JID in the expected format, and that there's a usable message body.  Then send the message out to all subscribers to this DID.

> 				| Just from <- mapToComponent =<< XMPP.messageFrom m,
> 				  Just txt <- getBody "jabber:client" m,
> 				  s"You are not authorized to send SMS messages." /= txt,
> 				  not (s"(SMSSERVER) " `T.isPrefixOf` txt) ->
> 					liftIO $ atomically $ mapM_ (\to ->
> 						sendToComponent $ mkStanzaRec ((mkSMS "jabber:component:accept" to txt) { XMPP.messageFrom = Just from })
> 					) subscribers

Otherwise Vitelity is just sending us some other thing we don't care about (like presence or something).  Ignore it for now.

> 			_ -> return ()

And that's it!  Of course, there's some more little helpers we should build to make the above work out.

We need a way to turn VitelityCredentials into an actual XMPP client connection to Vitelity.

> vitelityConnect :: (Unexceptional m, Monad m) => VitelityCredentials -> XMPP.XMPP () -> ExceptT XMPP.Error m ()
> vitelityConnect (VitelityCredentials did password) run =

Hoist any error response from `XMPP.runClient` into the `ExceptT` exception type.

> 	(hoistEither =<<) $

Catch any exceptions that might happen, map them to a "transport error", and report in `ExceptT`.

> 	fmapLT (XMPP.TransportError . show) $ syncIO $

Once we've set up the error mappings above, actually attempt the XMPP connection.

> 	XMPP.runClient smsServer jid did' password $ do
> 		void $ XMPP.bindJID jid
> 		run
> 	where

We can hard-code the server to connect to, since we know it's Vitelity's s.ms.

> 	smsServer = XMPP.Server (s"s.ms") "s.ms" (PortNumber 5222)

And also the server and resource to go along with the given DID to produce the login JID.
We store credentials in E.164 for future-proofing, but Vitelity expects NANP so do that conversion here as well.
A non-E.164 value stored in the db will crash the thread with a pattern match failure here.

> 	Just jid = XMPP.parseJID (did' ++ s"@s.ms/sgx")
> 	Just did' = T.stripPrefix (s"+1") did

We need a way to fetch vitelity credentials from the database for a particular source JID.

> fetchVitelityCredentials :: TC.HDB -> XMPP.JID -> IO (Maybe VitelityCredentials)
> fetchVitelityCredentials db from = do

Get whatever is at (or Nothing if the key does not exist) the key corresponding to the bare part of the from JID.

> 	maybeCredentialString <- TC.runTCM (TC.get db $ "registration\0" ++ textToString (bareTxt from))

Then try to parse the string as VitelityCredentials.

> 	return (readZ =<< maybeCredentialString)

We also want a way to format the XMPP stanzas we use to send SMS (both to Vitelity, and from Vitelity to subscribers).

> mkSMS :: String -> XMPP.JID -> Text -> XMPP.Message
> mkSMS namespace to txt = (XMPP.emptyMessage XMPP.MessageChat) {
> 	XMPP.messageTo = Just to,
> 	XMPP.messagePayloads = [Element (fromString $ "{" ++ namespace ++ "}body") [] [NodeContent $ ContentText txt]]
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

We encode the original sender into IDs sent to Vitelity so that we can reply errors properly.

> data SMSID = SMSID { smsidID :: Text, smsidFrom :: XMPP.JID }

> instance Show SMSID where
> 	show (SMSID sid from) = Prelude.show (sid, XMPP.formatJID from)

> instance Read SMSID where
> 	readsPrec n str = foldl' (\acc ((sid, fromS), leftover) ->
> 			case XMPP.parseJID fromS of
> 				Just from -> (SMSID sid from, leftover) : acc
> 				Nothing -> acc
> 		) [] (readsPrec n str)

It takes two lines to open a Tokyo Cabinet with the bindings we're using.  Too many lines!  Wrap it in a function.

> openTokyoCabinet :: (TC.TCDB a) => String -> IO a
> openTokyoCabinet pth = TC.runTCM $ do
> 	db <- TC.new
> 	True <- TC.open db pth [TC.OREADER, TC.OWRITER, TC.OCREAT]
> 	return db

This is the error to send back when we get a message to an invalid JID.

> invalidJidError :: Element
> invalidJidError = errorPayload "cancel" "item-not-found" (s"JID localpart must be in E.164 format.") []

This is the error to send back when we get a message from an unregistered JID.

> registrationRequiredError :: Element
> registrationRequiredError = errorPayload "auth" "registration-required" (s"You must be registered with Vitelity credentials to use this gateway.") []

This is the error to send back when we get a message with no body.

> noBodyError :: Element
> noBodyError = errorPayload "modify" "not-acceptable" (s"There was no body on the message you sent.") []

> vitelityAuthError :: Element
> vitelityAuthError = errorPayload "auth" "not-authorized" vitelityAuthErrorMsg []

> vitelityAuthErrorMsg :: Text
> vitelityAuthErrorMsg = s"There was an error connecting to Vitelity with the provided credentials."

> badRegistrationInfoError :: Element
> badRegistrationInfoError = errorPayload "modify" "not-acceptable" (s"Bad phone number format or missing password.") []

Helper to create an XMPP error payload with basic structure most errors need filled in.

> errorPayload :: String -> String -> Text -> [Node] -> Element
> errorPayload typ definedCondition english morePayload =
> 	Element (s"{jabber:component:accept}error")
> 	[(s"{jabber:component:accept}type", [ContentText $ fromString typ])]
> 	(
> 		(
> 			NodeElement $ Element (fromString $ "{urn:ietf:params:xml:ns:xmpp-stanzas}" ++ definedCondition) [] []
> 		) :
> 		(
> 			NodeElement $ Element (s"{urn:ietf:params:xml:ns:xmpp-stanzas}text")
> 				[(s"xml:lang", [ContentText $ s"en"])]
> 				[NodeContent $ ContentText english]
> 		) :
> 		morePayload
> 	)

Helper to convert a message to its equivalent error return.

> messageError :: Element -> XMPP.Message -> XMPP.Message
> messageError payload m = m {
> 	XMPP.messageType = XMPP.MessageError,

Reverse to and from so that the error goes back to the sender.

> 	XMPP.messageFrom = XMPP.messageTo m,
> 	XMPP.messageTo = XMPP.messageFrom m,

And append the extra error information to the payload.

> 	XMPP.messagePayloads = XMPP.messagePayloads m ++ [payload]
> }

And a similar helper for presence stanzas.

> presenceError :: Element -> XMPP.Presence -> XMPP.Presence
> presenceError payload p = p {
> 	XMPP.presenceFrom = XMPP.presenceTo p,
> 	XMPP.presenceTo = XMPP.presenceFrom p,
> 	XMPP.presencePayloads = XMPP.presencePayloads p ++ [payload]
> }

And similar helpers to reply to IQ stanzas with both success and error cases.

> iqReply :: Maybe Element -> XMPP.IQ -> XMPP.IQ
> iqReply payload iq = iq {
> 	XMPP.iqType = XMPP.IQResult,
> 	XMPP.iqFrom = XMPP.iqTo iq,
> 	XMPP.iqTo = XMPP.iqFrom iq,
> 	XMPP.iqPayload = payload
> }

> iqError :: Element -> XMPP.IQ -> XMPP.IQ
> iqError payload iq = (iqReply (Just payload) iq) {
> 	XMPP.iqType = XMPP.IQError
> }
