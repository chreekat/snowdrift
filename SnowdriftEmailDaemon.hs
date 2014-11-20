module Main where

import Import hiding (on)
import Model.Notification (NotificationType)
import Model.User         (deleteFromEmailVerification)

import           Control.Concurrent           (threadDelay)
import qualified Control.Exception.Lifted     as Exception
import           Control.Monad.Logger         (runLoggingT, LoggingT, defaultLogStr)
import           Control.Monad.Trans.Resource (runResourceT)
import           Database.Esqueleto
import qualified Data.ByteString.Char8        as Char8
import qualified Data.Function                as Function
import           Data.List                    (intercalate, nubBy)
import qualified Database.Persist             as Persist
import           Database.Persist.Postgresql  (PostgresConf)
import qualified Data.Text                    as Text
import qualified Data.Text.Encoding           as Text
import qualified Data.Text.Lazy               as TextLazy
import           Network.Mail.Mime            (renderSendMail, simpleMail', Address (..))
import           System.Console.CmdArgs
import           System.IO                    (stdout, stderr)
import           System.Environment           (getEnv, getProgName)
import           System.Log.FastLogger        (toLogStr, fromLogStr)
import qualified Text.Email.Validate          as Email
import           Yesod.Default.Config         (withYamlEnvironment, DefaultEnv (..))
import           Yesod.Markdown               (unMarkdown)

data SnowdriftEmailDaemon = SnowdriftEmailDaemon
    { db_arg    :: Text
    , email_arg :: Text
    , delay_arg :: Int
    } deriving (Typeable, Data, Show)

snowdriftEmailDaemon :: String -> String -> SnowdriftEmailDaemon
snowdriftEmailDaemon pname user = SnowdriftEmailDaemon
    { db_arg    = Text.pack default_db
               &= help ("Database to operate on " <>
                        "(default: " <> default_db <> ")")
               &= explicit &= name "db"
               &= typ "DATABASE"
    , email_arg = Text.pack (defaultEmail user)
               &= help ("Send notifications from this address " <>
                        "(default: " <> defaultEmail user <> ")")
               &= explicit &= name "email"
               &= typ "EMAIL"
    , delay_arg = default_delay
               &= help "Time between each iteration of the loop"
               &= explicit &= name "delay"
               &= typ "SECONDS"
    } &= summary "Snowdrift email daemon 0.1" &= program pname
      &= details ["Databases: " <> (intercalate ", " $ fst <$> databases)]
  where
    default_db    = "development"
    defaultEmail  = (<> "@localhost")
    default_delay = 10

databases :: [(String, DefaultEnv)]
databases = [ ("development", Development)
            , ("testing",     Testing)
            , ("staging",     Staging)
            , ("production",  Production) ]

type Email = Text
type Delay = Int

parse :: Text -> Email -> Int -> (DefaultEnv, Email, Delay)
parse db email delay = (env, notif_email, loop_delay)
  where
    env = case lookup (Text.unpack $ Text.toLower db) databases
          of Nothing -> error $ "unsupported database: "
                             <> Text.unpack db <> "; try '--help'"
             Just v  -> v
    notif_email =
        if Email.isValid $ Text.encodeUtf8 email
        then email
        else error $ "invalid email address format: " <> Text.unpack email
    loop_delay =
        if delay < 0
        then error $ "negative delay: " <> show delay
        else delay

-- | Select messages to users with verified email addresses.
selectWithVerifiedEmails :: (MonadResource m, MonadSqlPersist m)
                        => m [( Maybe Email, UTCTime, NotificationType
                            , UserId, Maybe ProjectId, Markdown )]
selectWithVerifiedEmails =
    (map (\(Value memail, Value ts, Value notif_type, Value to, Value mproject, Value content) ->
           (memail, ts, notif_type, to, mproject, content))) <$>
    (select $
     from $ \(notification_email `InnerJoin` user) -> do
         on $ notification_email ^. NotificationEmailTo ==.
              user ^. UserId
         where_ $ (not_ $ isNothing $ user ^. UserEmail)
              &&. user ^. UserEmail_verified
         return ( user ^. UserEmail
                , notification_email ^. NotificationEmailCreatedTs
                , notification_email ^. NotificationEmailType
                , notification_email ^. NotificationEmailTo
                , notification_email ^. NotificationEmailProject
                , notification_email ^. NotificationEmailContent ))

-- | Select all fields for users without email addresses or verified
-- email addresses such that they could be inserted into the
-- "notification" table without creating duplicates.
selectWithoutEmailsOrVerifiedEmails :: (MonadResource m, MonadSqlPersist m)
                    => m [( Value UTCTime
                          , Value NotificationType
                          , Value UserId
                          , Value (Maybe ProjectId)
                          , Value Markdown )]
selectWithoutEmailsOrVerifiedEmails =
    select $ from $ \(ne, user) -> do
        where_ $ ne ^. NotificationEmailTo ==. user ^. UserId
             &&. (isNothing $ user ^. UserEmail)
             ||. (not_ (isNothing $ user ^. UserEmail) &&.
                  not_ (user ^. UserEmail_verified))
             &&. ne ^. NotificationEmailTo
             `notIn` (subList_select $ from $ \n -> do
                          where_ $ n  ^. NotificationType
                               ==. ne ^. NotificationEmailType
                               &&. n  ^. NotificationTo
                               ==. ne ^. NotificationEmailTo
                               &&. n  ^. NotificationProject `notDistinctFrom`
                                   ne ^. NotificationEmailProject
                               &&. n  ^. NotificationContent
                               ==. ne ^. NotificationEmailContent
                          return (ne ^. NotificationEmailTo))
        return ( ne ^. NotificationEmailCreatedTs
               , ne ^. NotificationEmailType
               , ne ^. NotificationEmailTo
               , ne ^. NotificationEmailProject
               , ne ^. NotificationEmailContent )

insertWithoutEmailsOrVerifiedEmails :: ( MonadResource m, PersistMonadBackend m ~ SqlBackend
                                       , PersistStore m, MonadSqlPersist m ) => m ()
insertWithoutEmailsOrVerifiedEmails = do
    no_emails_or_not_verified <- selectWithoutEmailsOrVerifiedEmails
    forM_ no_emails_or_not_verified $
        \(Value ts, Value notif_type, Value to, Value mproject, Value content) -> do
            insert_ $ Notification ts notif_type to mproject content False
            deleteFromNotificationEmail ts notif_type to mproject content

fromNotificationEmail :: UTCTime -> NotificationType -> UserId
                      -> Maybe ProjectId -> Markdown -> SqlQuery ()
fromNotificationEmail ts notif_type to mproject content =
    from $ \ne -> do
        where_ $ ne ^. NotificationEmailCreatedTs ==. val ts
             &&. ne ^. NotificationEmailType      ==. val notif_type
             &&. ne ^. NotificationEmailTo        ==. val to
             &&. ne ^. NotificationEmailProject `notDistinctFrom` val mproject
             &&. ne ^. NotificationEmailContent   ==. val content

deleteFromNotificationEmail :: (MonadResource m, MonadSqlPersist m)
                            => UTCTime -> NotificationType -> UserId -> Maybe ProjectId
                            -> Markdown -> m ()
deleteFromNotificationEmail ts notif_type to mproject content =
    delete $ fromNotificationEmail ts notif_type to mproject content

insertIntoNotificationEmail :: ( MonadResource m, PersistStore m, MonadSqlPersist m
                               , PersistMonadBackend m ~ SqlBackend )
                            => UTCTime -> NotificationType -> UserId
                            -> Maybe ProjectId -> Markdown -> m ()
insertIntoNotificationEmail ts notif_type to mproject content = do
    n <- selectCount $ fromNotificationEmail ts notif_type to mproject content
    when (n == 0) $
        insert_ $ NotificationEmail ts notif_type to mproject content

handleSendmail :: (MonadBaseControl IO m, MonadIO m, MonadLogger m)
               => PostgresConf -> PersistConfigPool PostgresConf
               -> Text -> Email -> Email -> Text -> Text
               -> PersistConfigBackend PostgresConf m () -> Text -> m ()
handleSendmail dbConf poolConf info_msg from_ to subject body
               action warn_msg = do
    $(logInfo) info_msg
    Exception.handle handler $ do
        liftIO $ renderSendMail $ simpleMail'
            (Address Nothing to)
            (Address Nothing from_)
            subject
            (TextLazy.fromStrict body)
        runPool dbConf action poolConf
    where
      handler = \(err :: Exception.ErrorCall) -> do
          $(logError) (Text.pack $ show err)
          $(logWarn) warn_msg

sendNotification :: (MonadResource m, MonadBaseControl IO m, MonadIO m, MonadLogger m)
                 => PostgresConf -> PersistConfigPool PostgresConf
                 -> Email -> Email -> UTCTime -> NotificationType -> UserId
                 -> Maybe ProjectId -> Markdown -> m ()
sendNotification dbConf poolConf notif_email user_email ts notif_type to mproject content = do
    let content' = unMarkdown content
    handleSendmail dbConf poolConf
        ("sending a notification to " <> user_email <> "\n" <> content')
        notif_email user_email "Snowdrift.coop notification" content'
        (deleteFromNotificationEmail ts notif_type to mproject content)
        ("sending the notification to " <> user_email <> " failed; " <>
         "will try again later")

selectWithEmails :: (MonadResource m, MonadSqlPersist m)
                 => m [(UserId, Maybe Email, Text)]
selectWithEmails =
    fmap (map unwrapValues) $
    select $ from $ \(ev `InnerJoin` u) -> do
        on $ ev ^. EmailVerificationUser ==. u ^. UserId
        where_ $ not_ (isNothing $ u ^. UserEmail)
             &&. u ^. UserEmail ==. (just $ ev ^. EmailVerificationEmail)
             &&. not_ (ev ^. EmailVerificationSent)
        return ( u  ^. UserId
               , u  ^. UserEmail
               , ev ^. EmailVerificationUri )

selectWithoutEmails :: (MonadResource m, MonadSqlPersist m) => m [UserId]
selectWithoutEmails =
    fmap (map (\(Value user_id) -> user_id)) $
    select $ from $ \(ev `InnerJoin` u) -> do
        on $ ev ^. EmailVerificationUser ==. u ^. UserId
        where_ $ isNothing $ u ^. UserEmail
        return $ ev ^. EmailVerificationUser

deleteWithoutEmails :: (MonadResource m, MonadSqlPersist m) => m ()
deleteWithoutEmails = do
    no_emails <- selectWithoutEmails
    forM_ no_emails $ \user_id ->
        deleteFromEmailVerification user_id

selectWithNonMatchingEmails :: (MonadResource m, MonadSqlPersist m)
                            => m [(UserId, Text)]
selectWithNonMatchingEmails =
    fmap (map (\(Value user, Value email) -> (user, email))) $
    select $ from $ \(ev `InnerJoin` u) -> do
        on $ ev ^. EmailVerificationUser ==. u ^. UserId
        where_ $ not_ (isNothing $ u ^. UserEmail)
             &&. u ^. UserEmail !=. just (ev ^. EmailVerificationEmail)
        return ( ev ^. EmailVerificationUser
               , ev ^. EmailVerificationEmail )

deleteWithNonMatchingEmails :: (MonadResource m, MonadSqlPersist m) => m ()
deleteWithNonMatchingEmails = do
    non_matching <- selectWithNonMatchingEmails
    forM_ non_matching $ \(user, email) ->
        delete $ from $ \ev ->
            where_ $ ev ^. EmailVerificationUser  ==. val user
                 &&. ev ^. EmailVerificationEmail ==. val email

markAsSentVerification :: (MonadResource m, MonadSqlPersist m)
                       => UserId -> Email -> Text -> m ()
markAsSentVerification user_id user_email ver_uri =
    update $ \v -> do
        set v [EmailVerificationSent =. val True]
        where_ $ v ^. EmailVerificationUser  ==. val user_id
             &&. v ^. EmailVerificationEmail ==. val user_email
             &&. v ^. EmailVerificationUri   ==. val ver_uri

sendVerification :: (MonadResource m, MonadBaseControl IO m, MonadIO m, MonadLogger m)
                 => PostgresConf -> PersistConfigPool PostgresConf
                 -> Email -> UserId -> Email -> Text -> m ()
sendVerification dbConf poolConf verif_email user_id user_email ver_uri = do
    let content = "Please open this link to verify your email address: "
               <> ver_uri
    handleSendmail dbConf poolConf
        ("sending an email verification message to " <> user_email <> "\n" <>
         content)
        verif_email user_email "Snowdrift.coop email verification" content
        (markAsSentVerification user_id user_email ver_uri)
        ("sending the email verification message to " <> user_email <>
         " failed; will try again later")

selectUnsentResetPassword :: (MonadResource m, MonadSqlPersist m)
                          => m [(UserId, Email, Text)]
selectUnsentResetPassword =
    fmap (distinctFirst . map unwrapValues) $
    select $ from $ \rp -> do
        where_ $ not_ $ rp ^. ResetPasswordSent
        return ( rp ^. ResetPasswordUser
               , rp ^. ResetPasswordEmail
               , rp ^. ResetPasswordUri )
  where
    -- 'nub' is O(n^2).
    distinctFirst = nubBy ((==) `Function.on` (\(x,_,_) -> x))

markAsSentResetPassword :: (MonadResource m, MonadSqlPersist m)
                        => UserId -> m ()
markAsSentResetPassword user_id =
    update $ \rp -> do
        set rp [ResetPasswordSent =. val True]
        where_ $ rp ^. ResetPasswordUser ==. val user_id

sendResetPassword :: (MonadResource m, MonadBaseControl IO m, MonadLogger m)
                  => PostgresConf -> ConnectionPool -> Email -> Email
                  -> UserId -> Text -> m ()
sendResetPassword dbConf poolConf notif_email user_email user_id uri = do
    let content = "Please open this link to set the new password: " <> uri
    handleSendmail dbConf poolConf
        ("sending a password reset message to " <> user_email <> "\n" <> content)
        notif_email user_email "Snowdrift.coop password reset" content
        (markAsSentResetPassword user_id)
        ("sending the password reset message to " <> user_email <> " failed; " <>
         "will try again later")

withLogging :: MonadIO m => LoggingT m a -> m a
withLogging m = runLoggingT m $ \loc src level str ->
    let out = if level == LevelError then stderr else stdout
    in Char8.hPutStrLn out $
           fromLogStr $ defaultLogStr loc src level $ toLogStr str

withDelay :: MonadIO m => Delay -> m a -> m ()
withDelay delay action = action >> (liftIO $ threadDelay $ 1000000 * delay)

main :: IO ()
main = withLogging $ do
    pname <- liftIO $ getProgName
    userv <- liftIO $ getEnv "USER"
    SnowdriftEmailDaemon {..} <- liftIO $ cmdArgs $ snowdriftEmailDaemon pname userv
    -- Force evaluation to check the arguments first.
    let !(!env, !notif_email, !loop_delay) = parse db_arg email_arg delay_arg
    $(logInfo) "starting the daemon"
    $(logDebug) ("running with --db=" <> db_arg <> " --email=" <> notif_email <>
                 " --delay=" <> (Text.pack $ show loop_delay))
    (dbConf, poolConf) <- liftIO $ do
        dbConf   <- withYamlEnvironment "config/postgresql.yml" env
                        Persist.loadConfig >>= Persist.applyEnv :: IO PostgresConf
        poolConf <- Persist.createPoolConfig dbConf
        return (dbConf, poolConf)
    $(logInfo) "starting the main loop"
    void $ forever $ runResourceT $ withDelay loop_delay $ do
        let action = do
                with_emails <- selectWithVerifiedEmails
                insertWithoutEmailsOrVerifiedEmails
                return with_emails

        notifs <- runPool dbConf action poolConf
        forM_ notifs $ \(Just user_email, ts, notif_type, to, mproject, content) ->
            sendNotification dbConf poolConf notif_email user_email ts notif_type to mproject content
        let action' = do
                with_emails <- selectWithEmails
                deleteWithNonMatchingEmails
                deleteWithoutEmails
                return with_emails
        verifs <- runPool dbConf action' poolConf
        forM_ verifs $ \(user_id, Just user_email, ver_uri) ->
            sendVerification dbConf poolConf notif_email user_id user_email ver_uri
        resets <- runPool dbConf selectUnsentResetPassword poolConf
        forM_ resets $ \(user_id, user_email, uri) ->
            sendResetPassword dbConf poolConf notif_email user_email user_id uri