module Model.User.Internal where

import Prelude
import Import
import Model.Notification
    ( NotificationType (..), NotificationDelivery (..)
    , sendNotificationDB_, sendNotificationEmailDB )

import qualified Data.Foldable      as F
import qualified Data.List.NonEmpty as N
import Data.List.NonEmpty (NonEmpty)

import Control.Monad.Trans.Maybe

data UserUpdate =
    UserUpdate
        { userUpdateName               :: Maybe Text
        , userUpdateAvatar             :: Maybe Text
        , userUpdateEmail              :: Maybe Text
        , userUpdateIrcNick            :: Maybe Text
        , userUpdateBlurb              :: Maybe Markdown
        , userUpdateStatement          :: Maybe Markdown
        }

data ChangePassword = ChangePassword
    { currentPassword :: Text
    , newPassword     :: Text
    , newPassword'    :: Text
    }

data SetPassword = SetPassword
    { password  :: Text
    , password' :: Text
    }

data NotificationPref = NotificationPref
    { -- 'NotifWelcome' and 'NotifEligEstablish' are not handled since
      -- they are delivered only once.
      notifBalanceLow        :: NonEmpty NotificationDelivery
    , notifUnapprovedComment :: Maybe (NonEmpty NotificationDelivery)
    , notifRethreadedComment :: Maybe (NonEmpty NotificationDelivery)
    , notifReply             :: Maybe (NonEmpty NotificationDelivery)
    , notifEditConflict      :: NonEmpty NotificationDelivery
    , notifFlag              :: NonEmpty NotificationDelivery
    , notifFlagRepost        :: Maybe (NonEmpty NotificationDelivery)
    } deriving Show


forcedNotification :: NotificationType -> Maybe (NonEmpty NotificationDelivery)
forcedNotification NotifWelcome             = Just $ return NotifDeliverWebsite
forcedNotification NotifEligEstablish       = Just $ return NotifDeliverWebsite
forcedNotification NotifBalanceLow          = Nothing
forcedNotification NotifUnapprovedComment   = Nothing
forcedNotification NotifApprovedComment     = Nothing
forcedNotification NotifRethreadedComment   = Nothing
forcedNotification NotifReply               = Nothing
forcedNotification NotifEditConflict        = Nothing
forcedNotification NotifFlag                = Nothing
forcedNotification NotifFlagRepost          = Nothing


-- | How does this User prefer notifications of a certain type to be delivered?
fetchUserNotificationPrefDB :: UserId -> NotificationType -> DB (Maybe (NonEmpty NotificationDelivery))
fetchUserNotificationPrefDB user_id notif_type = runMaybeT $ mplus forced pulled
  where
    forced = MaybeT $ return $ forcedNotification notif_type

    pulled = MaybeT $ fmap (N.nonEmpty . unwrapValues) $ select $ from $ \ unp -> do
        where_ $ unp ^. UserNotificationPrefUser ==. val user_id
            &&. unp ^. UserNotificationPrefType ==. val notif_type
        return $ unp ^. UserNotificationPrefDelivery


fetchUserEmail :: UserId -> DB (Maybe Text)
fetchUserEmail user_id
    = (\case []    -> Nothing
             (x:_) -> unValue x)
  <$> (select $ from $ \user -> do
           where_ $ user ^. UserId ==. val user_id
           return $ user ^. UserEmail)

fetchUserEmailVerified :: UserId -> DB Bool
fetchUserEmailVerified user_id =
    fmap (\[Value b] -> b) $
    select $ from $ \user -> do
        where_ $ user ^. UserId ==. val user_id
        return $ user ^. UserEmail_verified

-- | Perform an action (or actions) according to the selected
-- 'NotificationDelivery' method.
sendPreferredNotificationDB :: UserId -> NotificationType -> Maybe ProjectId
                            -> Maybe CommentId-> Markdown -> SDB ()
sendPreferredNotificationDB user_id notif_type mproject_id mcomment_id content = do
    mprefs <- lift $ fetchUserNotificationPrefDB user_id notif_type

    F.forM_ mprefs $ \ prefs -> F.forM_ prefs $ \ pref -> do
        muser_email    <- lift $ fetchUserEmail user_id
        email_verified <- lift $ fetchUserEmailVerified user_id
        -- XXX: Support 'NotifDeliverEmailDigest'.
        if | pref == NotifDeliverEmail && isJust muser_email && email_verified ->
                lift $ sendNotificationEmailDB notif_type user_id mproject_id content
           | otherwise -> do
                 r <- selectCount $ from $ \n -> do
                          where_ $ n ^. NotificationType    ==. val notif_type
                               &&. n ^. NotificationTo      ==. val user_id
                               &&. n ^. NotificationProject `notDistinctFrom` val mproject_id
                               &&. n ^. NotificationContent ==. val content
                 when (r == 0) $
                     sendNotificationDB_ notif_type user_id mproject_id mcomment_id content
