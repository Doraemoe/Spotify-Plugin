//
//  QSSpotifyUtil.m
//  Spotify Plugin
//
//  Created by Jin Yifan on 14-4-28.
//  Copyright (c) 2014年 Jin Yifan. All rights reserved.
//

#import "QSSpotifyUtil.h"
#import "QSSpotifyPrefPane.h"
#import "QSSpotifyDefines.h"

@implementation QSSpotifyUtil

+ (void)initialize {
    [QSSpotifyUtil sharedInstance];
}

+ (QSSpotifyUtil *)sharedInstance {
    static QSSpotifyUtil *su = nil;
    static dispatch_once_t once_token;
    
    dispatch_once(&once_token, ^{
        su = [[QSSpotifyUtil alloc] init];
    });
    return su;
}

- (id)init
{
    if (self = [super init]) {
        _accessToken = kAccessTokenPlaceholder;
        _refreshToken = kRefreshTokenPlaceholder;
        _displayName = kDisplayNamePlaceholder;
        _trackID = kTrackIDPlaceholder;
        _trackURI = kTrackURIPlaceholder;
        _playlistID = kPlaylistIDPlaceholder;
        
        _tokenStartTime = 0;
        _tokenExpiresIn = 0;
        
        _needPlaylists = NO;
        _needUserID = NO;
        _needSaveTrack = NO;
        _needTrackInPlaylist = NO;
        _needFollowArtist = NO;
        
        _totalPlaylistsNumber = 0;
        _oldPlaylistsSet = nil;
        _playlists = nil;
        _tracksInPlaylist = nil;

        _Spotify = QSSpotify();
        /*
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(loadStart:)
                                                     name:WebViewProgressStartedNotification
                                                   object:nil];
         */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(loadFinished:)
                                                     name:WebViewProgressFinishedNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playlistsAdded:)
                                                     name:PlaylistItemsAddedJobFinishedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(profileGet:)
                                                     name:UserProfileDidGetNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(tokenGet:)
                                                     name:AccessTokenDidGetNotification
                                                   object:nil];
        
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                            selector:@selector(playbackChanged:)
                                                                name:@"com.spotify.client.PlaybackStateChanged"
                                                              object:nil];


        
    }
    return self;
}

#pragma mark -
#pragma mark notification

- (void)playlistsAdded:(NSNotification *)note {
    if (_playlists.count == _totalPlaylistsNumber) {
        if (_oldPlaylistsSet == nil) {
            //NSLog(@"hard refresh");
            _oldPlaylistsSet = [NSSet setWithArray:_playlists];
            [[NSNotificationCenter defaultCenter] postNotificationName:QSCatalogSourceInvalidated object:@"QSSpotifyObjectSource"];
        }
        else {
            NSSet *newPlaylistsSet = [NSSet setWithArray:_playlists];
            if (![_oldPlaylistsSet isEqualToSet:newPlaylistsSet]) {
                //NSLog(@"hard refrsh");
                _oldPlaylistsSet = [NSSet setWithArray:_playlists];
                [[NSNotificationCenter defaultCenter] postNotificationName:QSCatalogSourceInvalidated object:@"QSSpotifyObjectSource"];
            }
        }
    }

}
/*
- (void)loadStart:(NSNotification *)note {
    NSString *url = _web.mainFrame.provisionalDataSource.request.URL.absoluteString;
    
    if ([url length] > 26 && [[url substringToIndex:kRedirect.length] compare:kRedirect] == NSOrderedSame) {
        [self finishAuthWithCallback:url];
    }
}
*/
- (void)loadFinished:(NSNotification *)note {
    NSString *url = _web.mainFrame.dataSource.request.URL.absoluteString;

    if ([url length] > 26 && [[url substringToIndex:kRedirect.length] compare:kRedirect] == NSOrderedSame) {
        [self finishAuthWithCallback:url];
    }
}

- (void)profileGet:(NSNotification *)note {
    if (_needPlaylists) {
        _needPlaylists = NO;
        [self getPlaylists];
    }
}

- (void)tokenGet:(NSNotification *)note {
    if (_needUserID) {
        _needUserID = NO;
        [self accessUserProfile];
    }
    
    if (_needSaveTrack) {
        _needSaveTrack = NO;
        [self saveTrack];
    }
    
    if (_needFollowArtist) {
        _needFollowArtist = NO;
        [self getArtistID];
    }
    
    if (_needSaveTrackToPlaylist) {
        _needSaveTrackToPlaylist = NO;
        [self saveToPlaylist];
    }
}

- (void)playbackChanged:(NSNotification *)noti {
    NSDictionary *info = [noti userInfo];
    
    if ([[info objectForKey:@"Player State"] isEqualToString:@"Playing"]) {
        NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowTrackNotification"];
        if (allowNotification == NSOnState) {
            [self showCurrentTrackNotification];
        }
    }
}
#pragma mark -
#pragma mark auth

- (void)attemptLoginWithPrivate:(NSInteger)allowPrivate {
    NSString *scope;
    if (allowPrivate == NSOnState) {
        scope = @"playlist-modify-public user-library-read user-library-modify user-follow-modify playlist-read-private playlist-modify-private";
    }
    else {
        scope = @"playlist-modify-public user-library-read user-library-modify user-follow-modify";
    }
    
    [self createLoginWindow];

    NSDictionary *parameters = @{@"response_type": @"code",
                                 @"redirect_uri": kRedirect,
                                 @"client_id": kClientID,
                                 @"scope": scope};
    
    NSURLRequest *urlRequest = [[AFHTTPRequestSerializer serializer] requestWithMethod:@"GET"
                                                                             URLString:kAuthorization
                                                                            parameters:parameters
                                                                                 error:nil];
    [[_web mainFrame] loadRequest:urlRequest];

}

-(BOOL)windowShouldClose:(id)sender {
    //NSString *url = _web.mainFrame.dataSource.request.URL.absoluteString;
    //NSLog(@"url is: %@", url);
    [self signOut];
    return YES;
}

- (void)finishAuthWithCallback:(NSString *)callback {
    
    [_codeWindow close];
    
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *clientIDandSecretString = [NSString stringWithFormat:@"%@:%@", kClientID, kClientSecret];
    NSString *encodedIDandSec = [NSString stringWithFormat:@"Basic %@", base64enc(clientIDandSecretString)];
    
    [manager.requestSerializer setValue:encodedIDandSec forHTTPHeaderField:@"Authorization"];
    
    NSDictionary *parameters = @{@"grant_type": @"authorization_code",
                                 @"code": [callback substringFromIndex:33],
                                 @"redirect_uri": kRedirect
                                 };

    
    [manager POST:kToken
       parameters:parameters
          success:^(NSURLSessionTask *task, NSDictionary *tokenData) {
              
              _accessToken = [tokenData valueForKey:@"access_token"];
              _refreshToken = [tokenData valueForKey:@"refresh_token"];
              _tokenExpiresIn = [[tokenData valueForKey:@"expires_in"] integerValue];
              _tokenStartTime = [[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] integerValue];
              [self storeRefreshToken];
              
              [[NSNotificationCenter defaultCenter] postNotificationName:AccessTokenDidGetNotification object:nil];
          }
          failure:^(NSURLSessionTask *task, NSError *error) {
              NSLog(@"Error: %@", error);
          }];
}

- (void)requestAccessTokenFromRefreshToken {
    
    NSInteger currentTime = [[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] integerValue];

    if (currentTime - _tokenStartTime < _tokenExpiresIn - 10) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AccessTokenDidGetNotification object:nil];
        
        return;
    }
    
    if ([_refreshToken compare:kRefreshTokenPlaceholder] == NSOrderedSame) {
        _refreshToken = [self getRefreshToken];
    }
    
    if ([_refreshToken compare:kRefreshTokenPlaceholder] == NSOrderedSame) {
        return;
    }
    
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *clientIDandSecretString = [NSString stringWithFormat:@"%@:%@", kClientID, kClientSecret];
    NSString *encodedIDandSec = [NSString stringWithFormat:@"Basic %@", base64enc(clientIDandSecretString)];
    
    [manager.requestSerializer setValue:encodedIDandSec forHTTPHeaderField:@"Authorization"];
    
    NSDictionary *parameters = @{@"grant_type": @"refresh_token",
                                 @"refresh_token": _refreshToken
                                 };
    
    [manager POST:kToken
       parameters:parameters
          success:^(NSURLSessionTask *task, NSDictionary *tokenData) {
              _accessToken = [tokenData valueForKey:@"access_token"];
              _tokenExpiresIn = [[tokenData valueForKey:@"expires_in"] integerValue];
              _tokenStartTime = [[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] integerValue];
              
              [[NSNotificationCenter defaultCenter] postNotificationName:AccessTokenDidGetNotification object:nil];
          }
          failure:^(NSURLSessionTask *task, NSError *error) {
              NSLog(@"Error: %@", error);
          }];
}

- (void)createLoginWindow {
    NSRect frame = NSMakeRect(100, 100, 1024, 768);
    _codeWindow  = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    [_codeWindow setReleasedWhenClosed:NO];
    [_codeWindow setDelegate:self];
    [_codeWindow setBackgroundColor:[NSColor blueColor]];
    [_codeWindow setTitle:@"Authorization"];
    _web = [WebView new];
    [_codeWindow setContentView:_web];
    [_codeWindow makeKeyAndOrderFront:NSApp];
}

- (void)signOut {
    _accessToken = @"AccessTokenPlaceholder";
    _refreshToken = @"RefreshTokenPlaceholder";
    _displayName = @"NamePlaceholder";
    _trackID = @"trackIDPlaceholder";
    _trackURI = @"trackURIPlaceholder";
    _playlistID = @"playlistIDPlaceholder";
    _tokenStartTime = 0;
    _tokenExpiresIn = 0;
    _needPlaylists = NO;
    _needUserID = NO;
    _needSaveTrack = NO;
    _needTrackInPlaylist = NO;
    _oldPlaylistsSet = nil;
    _playlists = nil;
    _tracksInPlaylist = nil;
    
    OSStatus status;
    char *usr = (char *)[@"Spotify" UTF8String];
    status = DelPasswordKeychain(usr);
    
    [_prefPane finishLogout];
}

#pragma mark -
#pragma mark function

- (void)accessUserProfile {
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *accessHeader = [NSString stringWithFormat:@"Bearer %@", _accessToken];
    [manager.requestSerializer setValue:accessHeader forHTTPHeaderField:@"Authorization"];
    
    [manager GET:kCurrectUserProfile
      parameters:nil
         success:^(NSURLSessionTask *task, NSDictionary *userProfile) {
             //NSLog(@"access profile");
             _userID = [userProfile valueForKey:@"id"];
             _displayName = [userProfile valueForKey:@"display_name"];
             
             [[NSNotificationCenter defaultCenter] postNotificationName:UserProfileDidGetNotification object:nil];
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
         }];
}

- (void)getPlaylistsWithOffset:(NSString *)offset limit:(NSString *)limit manager:(AFHTTPSessionManager *)manager {
    
    NSString *url = [kUserPlaylistsWildcard stringByReplacingOccurrencesOfString:@"USERID" withString:_userID];
    
    NSDictionary *parameters = @{@"offset": offset,
                                 @"limit": limit,
                                 };
    
    
    [manager GET:url
      parameters:parameters
         success:^(NSURLSessionTask *task, NSDictionary *playlistData) {
             //NSLog(@"limit: %@, offset: %@", [playlistData valueForKey:@"limit"], [playlistData valueForKey:@"offset"]);
             
             [_playlists addObjectsFromArray:[playlistData valueForKey:@"items"]];
             
             NSArray *playlists = [playlistData valueForKey:@"items"];
             for (NSDictionary *playlist in playlists) {
                 NSString *tracksLocation = [[playlist valueForKey:@"tracks"] valueForKey:@"href"];
                 NSString *name = [playlist valueForKey:@"name"];
                 [self getTrackInPlaylistWithEndpoint:tracksLocation name:name];
             }
             
             [[NSNotificationCenter defaultCenter] postNotificationName:PlaylistItemsAddedJobFinishedNotification object:nil];
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
         }];
    
}

- (void)getPlaylists {
    
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *accessHeader = [NSString stringWithFormat:@"Bearer %@", _accessToken];
    [manager.requestSerializer setValue:accessHeader forHTTPHeaderField:@"Authorization"];
    
    NSString *url = [kUserPlaylistsWildcard stringByReplacingOccurrencesOfString:@"USERID" withString:_userID];
    
    NSDictionary *parameters = @{@"offset": @"0",
                                 @"limit": @"50",
                                 };
    
    
    [manager GET:url
      parameters:parameters
         success:^(NSURLSessionTask *task, NSDictionary *playlistData) {
             
             //NSLog(@"total: %@", [playlistData valueForKey:@"total"]);
             //NSLog(@"limit: %@, offset: %@", [playlistData valueForKey:@"limit"], [playlistData valueForKey:@"offset"]);
             
             _totalPlaylistsNumber = [[playlistData valueForKey:@"total"] integerValue];
             _playlists = [[NSMutableArray alloc] initWithCapacity:_totalPlaylistsNumber];
             _tracksInPlaylist = [[NSMutableDictionary alloc] initWithCapacity:_totalPlaylistsNumber];
             [_playlists addObjectsFromArray:[playlistData valueForKey:@"items"]];
             
             NSArray *playlists = [playlistData valueForKey:@"items"];
             for (NSDictionary *playlist in playlists) {
                 NSString *tracksLocation = [[playlist valueForKey:@"tracks"] valueForKey:@"href"];
                 NSString *name = [playlist valueForKey:@"name"];
                 [self getTrackInPlaylistWithEndpoint:tracksLocation name:name];
             }
             
             NSInteger totalLeft = _totalPlaylistsNumber - 50;
             int offset = 50;
             
             while (totalLeft > 0) {
                 [self getPlaylistsWithOffset:[NSString stringWithFormat:@"%d", offset] limit:@"50" manager:manager];
                 totalLeft -= 50;
                 offset += 50;
             }
             [[NSNotificationCenter defaultCenter] postNotificationName:PlaylistItemsAddedJobFinishedNotification object:nil];
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
         }];
}

- (void)getTrackInPlaylistWithEndpoint:(NSString *)endpoint name:(NSString *)playlistName {
    //NSLog(@"endpoint: %@ playlist: %@", endpoint, playlistName);
    //NSLog(@"playlistname %@", playlistName);
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *accessHeader = [NSString stringWithFormat:@"Bearer %@", _accessToken];
    [manager.requestSerializer setValue:accessHeader forHTTPHeaderField:@"Authorization"];
    
    NSDictionary *parameters = @{@"fields": @"total,items(track(name,id,uri,album(images),artists(name)))"};
    
    [manager GET:endpoint
      parameters:parameters
         success:^(NSURLSessionTask *task, NSDictionary *tracksData) {
             NSMutableArray *tracksArray = [[NSMutableArray alloc] initWithCapacity:[[tracksData valueForKey:@"total"] integerValue]];
             //NSLog(@"%@", tracksData);

             for (NSDictionary *track in [[tracksData valueForKey:@"items"] valueForKey:@"track"]) {
                 NSString *name = [track valueForKey:@"name"];
                 NSString *trackID = [track valueForKey:@"id"];
                 NSString *uri = [track valueForKey:@"uri"];
                 NSArray *artistsName = [[track valueForKey:@"artists"] valueForKey:@"name"];
                 NSArray *url = [[[track valueForKey:@"album"] valueForKey:@"images"] valueForKey:@"url"];
            
                 //NSLog(@"name: %@ trackID: %@ uri: %@ artistName: %@ url: %@", name, trackID, uri, artistsName, url);
                 
                 if ((NSNull *)artistsName == [NSNull null] || artistsName == nil || [artistsName count] < 1 ) {
                     continue;
                 }
                 if ((NSNull *)url == [NSNull null] || url == nil || [url count] < 2 ) {
                     continue;
                 }
                 
                 if ((NSNull *)name != [NSNull null] &&
                     (NSNull *)uri != [NSNull null] &&
                     (NSNull *)artistsName[0] != [NSNull null] &&
                     (NSNull *)url != [NSNull null] &&
                     (NSNull *)trackID != [NSNull null] &&
                     (NSNull *)url[1] != [NSNull null]) {
                     
                     QSObject *newObject = [QSObject objectWithString:name];
                     [newObject setLabel:name];
                     [newObject setObject:uri forType:QSSpotifyTrackType];
                     [newObject setPrimaryType:QSSpotifyTrackType];
                     [newObject setIdentifier:[@"SpotifyTrack" stringByAppendingString:trackID]];
                     [newObject setDetails:artistsName[0]];
                     [newObject setObject:url[1] forMeta:@"coverImage"];
                     
                     
                     [tracksArray addObject:newObject];
                 }
             }

             
             [_tracksInPlaylist setObject:tracksArray forKey:playlistName];
             //NSLog(@"%@", [_tracksInPlaylist objectForKey:playlistName]);
            
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
         }];
    

}



- (void)saveSongWithID:(NSString *) ID {
    _needSaveTrack = YES;
    _trackID = ID;
    [self requestAccessTokenFromRefreshToken];
}

- (void)saveTrack {
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];

    NSString *accessHeader = [NSString stringWithFormat:@"Bearer %@", _accessToken];
    [manager.requestSerializer setValue:accessHeader forHTTPHeaderField:@"Authorization"];
    
    NSString *url = [kSaveTrackForMe stringByReplacingOccurrencesOfString:@"TRACKID" withString:_trackID];
    
    [manager PUT:url
      parameters:nil
         success:^(NSURLSessionTask *task, NSDictionary *returnData) {
             //NSLog(@"%@", returnData);
             NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowNotification"];
             if (allowNotification == NSOnState) {
                 
                 QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Song Saved to My Music", QSNotifierTitle,
                                               @"Music Video", QSNotifierStyle,
                                               nil]);
             }

         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
             NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowNotification"];
             if (allowNotification == NSOnState) {
                 
                 QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Failed to Save the Song to My Music", QSNotifierTitle,
                                               @"Music Video", QSNotifierStyle,
                                               nil]);
             }
         }];
    
    _trackID = @"trackIDPlaceholder";
}

- (void)followArtistWithID:(NSString *)ID {
    _needFollowArtist = YES;
    _trackID = ID;
    [self requestAccessTokenFromRefreshToken];
}

- (void)getArtistID {
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSString *url = [kTrackInfo stringByReplacingOccurrencesOfString:@"TRACKID" withString:_trackID];
    
    [manager GET:url
      parameters:nil
         success:^(NSURLSessionTask *task, NSDictionary *returnData) {
             //NSLog(@"%@", returnData);
             NSArray *artistID = [[returnData valueForKey:@"artists"] valueForKey:@"id"];
             [self followArtist:artistID];
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
         }];
}


     
- (void)followArtist:(NSArray *)artistID {
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *accessHeader = [NSString stringWithFormat:@"Bearer %@", _accessToken];
    [manager.requestSerializer setValue:accessHeader forHTTPHeaderField:@"Authorization"];

    manager.requestSerializer.HTTPMethodsEncodingParametersInURI = [NSSet setWithObjects:@"GET", @"HEAD", @"DELETE", @"PUT", nil];
    
    NSDictionary *parameters = @{@"type": @"artist",
                                 @"ids": artistID[0],
                                 };
    
    [manager PUT:kFollowArtist
      parameters:parameters
         success:^(NSURLSessionTask *task, NSDictionary *returnData) {
             NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowNotification"];
             if (allowNotification == NSOnState) {
                 
                 QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Followed Successful", QSNotifierTitle,
                                               @"Music Video", QSNotifierStyle,
                                               nil]);
             }
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
             NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowNotification"];
             if (allowNotification == NSOnState) {
                 
                 QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Failded to Follow Artist", QSNotifierTitle,
                                               @"Music Video", QSNotifierStyle,
                                               nil]);
             }
         }];

}

- (void)addTrack:(NSString *)uri toPlaylist:(NSString *)playlistID {
    _needSaveTrackToPlaylist = YES;
    _trackURI = uri;
    _playlistID = playlistID;
    
    [self requestAccessTokenFromRefreshToken];
}

- (void)saveToPlaylist {
    //AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSString *accessHeader = [NSString stringWithFormat:@"Bearer %@", _accessToken];
    [manager.requestSerializer setValue:accessHeader forHTTPHeaderField:@"Authorization"];
    
    NSString *url = [kSaveTrackForPlaylist stringByReplacingOccurrencesOfString:@"USERID" withString:_userID];
    url = [url stringByReplacingOccurrencesOfString:@"PLAYLISTID" withString:_playlistID];
    url = [url stringByReplacingOccurrencesOfString:@"URI" withString:_trackURI];
    
    //NSLog(@"%@",url);
    
    [manager POST:url
      parameters:nil
         success:^(NSURLSessionTask *task, NSDictionary *returnData) {
             //NSLog(@"%@", returnData);
             NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowNotification"];
             if (allowNotification == NSOnState) {
                 
                 QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Song Saved to Playlist", QSNotifierTitle,
                                               @"Music Video", QSNotifierStyle,
                                               nil]);
             }
         }
         failure:^(NSURLSessionTask *task, NSError *error) {
             NSLog(@"Error: %@", error);
             NSInteger allowNotification = [[NSUserDefaults standardUserDefaults] integerForKey:@"allowNotification"];
             if (allowNotification == NSOnState) {
                 
                 QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Failed to Save Song to Playlist", QSNotifierTitle,
                                               @"Music Video", QSNotifierStyle,
                                               nil]);
             }
         }];

    _trackURI = kTrackIDPlaceholder;
    _playlistID = kPlaylistIDPlaceholder;
}

- (void)showCurrentTrackNotification {
    QSObject *playingTrack = nil;
    
    if ([[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"] count] == 0) {
        return;
    }
    if ([_Spotify playerState] == SpotifyEPlSPlaying || [_Spotify playerState] == SpotifyEPlSPaused) {
        SpotifyTrack *track = [_Spotify currentTrack];
        NSString *name = [track name];
        NSString *trackID = [track id];
        NSString *uri = [track spotifyUrl];
        NSString *artist = [track artist];
        NSString *album = [track album];
        NSImage *cover = [track artwork];
        
        if ((NSNull *)name != [NSNull null] && (NSNull *)trackID != [NSNull null] && (NSNull *)uri != [NSNull null] && (NSNull *)artist != [NSNull null]) {
            playingTrack = [QSObject objectWithString:name];
            [playingTrack setLabel:name];
            [playingTrack setObject:uri forType:QSSpotifyTrackType];
            [playingTrack setPrimaryType:QSSpotifyTrackType];
            [playingTrack setIdentifier:@"SpotifyCurrentTrackProxy"];
            [playingTrack setDetails:artist];
            [playingTrack setObject:cover forMeta:@"coverImage"];
            
            
            if (!cover) {
                cover = [QSResourceManager imageNamed:@"￼￼/Applications/Spotify.app/Contents/Resources/Icon.icns"];
            }
            
            
            //[[NSNotificationCenter defaultCenter] postNotificationName:@"QSEventNotification" object:TrackChangeNotification userInfo:[NSDictionary dictionaryWithObject:playingTrack forKey:@"object"]];
            
            //[[NSNotificationCenter defaultCenter] postNotificationName:@"QSSpotifyTrackChangeEvent" object:self userInfo:[playingTrack dictionaryRepresentation]];
            
            QSShowNotifierWithAttributes([NSDictionary dictionaryWithObjectsAndKeys:
                                          @"QSSpotifyTrackChangeEvent", QSNotifierType,
                                          name, QSNotifierTitle,
                                          [NSString stringWithFormat:@"%@\n%@",artist, album], QSNotifierText,
                                          cover, QSNotifierIcon,
                                          @"Music Video", QSNotifierStyle,
                                          album, QSNotifierDetails,
                                          nil]);
            
        }
        
    }
}

#pragma mark -
#pragma mark keychain

//Call SecKeychainAddGenericPassword to add a new password to the keychain:
OSStatus StorePasswordKeychain (void* password, UInt32 passwordLength, char *acctName)
{
    OSStatus status;
    status = SecKeychainAddGenericPassword (
                                            NULL,            // default keychain
                                            11,              // length of service name
                                            "SpotifyAuth",    // service name
                                            (UInt32)strlen(acctName),              // length of account name
                                            acctName,    // account name
                                            passwordLength,  // length of password
                                            password,        // pointer to password data
                                            NULL             // the item reference
                                            );
    return (status);
}

//Call SecKeychainFindGenericPassword to get a password from the keychain:
OSStatus GetPasswordKeychain (void **passwordData, UInt32 *passwordLength,
                              SecKeychainItemRef *itemRef, char *acctName)
{
    OSStatus status1 ;
    
    
    status1 = SecKeychainFindGenericPassword (
                                              NULL,           // default keychain
                                              11,             // length of service name
                                              "SpotifyAuth",   // service name
                                              (UInt32)strlen(acctName),             // length of account name
                                              acctName,   // account name
                                              passwordLength,  // length of password
                                              passwordData,   // pointer to password data
                                              itemRef         // the item reference
                                              );
    return (status1);
}

OSStatus DelPasswordKeychain (char *acctName) {
    OSStatus status;

    void *passwordData = NULL;
    SecKeychainItemRef itemRef = NULL;
    UInt32 passwordDataLength = 0;
    
    status = GetPasswordKeychain(&passwordData, &passwordDataLength, &itemRef, acctName);
    
    if (status == noErr) {
        SecKeychainItemFreeContent(NULL, passwordData);
        status = SecKeychainItemDelete(itemRef);
        
    }
    else if (status == errSecItemNotFound) {
        //safe
        SecKeychainItemFreeContent(NULL, passwordData);
    }
    
    return status;
}

- (void)storeRefreshToken {
    //NSLog(@"saving Token");
    OSStatus status;
    
    char *usr = (char *)[@"Spotify" UTF8String];
    void *password = (char *)[_refreshToken UTF8String];
    
    size_t passwordLength = strlen(password);
    assert(passwordLength <= 0xffffffff);
    
    void *passwordData = NULL;
    SecKeychainItemRef itemRef = NULL;
    UInt32 passwordDataLength = 0;
    
    
    status = GetPasswordKeychain(&passwordData, &passwordDataLength, &itemRef, usr);
    
    if (status == noErr) {
        //already in keychain
        status = DelPasswordKeychain(usr);
        status = StorePasswordKeychain(password, (UInt32)passwordLength, usr);
    }
    else if (status == errSecItemNotFound) {
        status = StorePasswordKeychain(password, (UInt32)passwordLength, usr);
    }
    
}

- (NSString *)getRefreshToken {
    NSString *refreshToken = kRefreshTokenPlaceholder;
    OSStatus status;
    void *passwordData = NULL;
    SecKeychainItemRef itemRef = NULL;
    UInt32 passwordDataLength = 0;
    char *usr = (char *)[@"Spotify" UTF8String];
    
    status = GetPasswordKeychain(&passwordData, &passwordDataLength, &itemRef, usr);
    if (status == noErr) {
        refreshToken = [[NSString alloc] initWithBytes:passwordData
                                                      length:passwordDataLength
                                                    encoding:NSUTF8StringEncoding];
        SecKeychainItemFreeContent(NULL, passwordData);
    }
    else if (status == errSecItemNotFound) {
        //NSLog(@"error not found");
        SecKeychainItemFreeContent(NULL, passwordData);
    }
    return refreshToken;
}

#pragma mark -
#pragma mark base64encode

static NSData *base64helper(NSData *input, SecTransformRef transform)
{
    NSData *output = nil;
    
    if (!transform)
        return nil;
    
    if (SecTransformSetAttribute(transform, kSecTransformInputAttributeName, (__bridge CFTypeRef)(input), NULL))
        output = (NSData *)CFBridgingRelease(SecTransformExecute(transform, NULL));
    
    CFRelease(transform);
    
    return output;
}

NSString *base64enc(NSString *originalString)
{
    NSData *data = [NSData dataWithBytes:[originalString UTF8String] length:originalString.length];
    
    SecTransformRef transform = SecEncodeTransformCreate(kSecBase64Encoding, NULL);
    
    return [[NSString alloc] initWithData:base64helper(data, transform) encoding:NSASCIIStringEncoding];
}

NSData *base64dec(NSString *input)
{
    SecTransformRef transform = SecDecodeTransformCreate(kSecBase64Encoding, NULL);
    
    return base64helper([input dataUsingEncoding:NSASCIIStringEncoding], transform);
}

@end
