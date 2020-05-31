#import "NSData+AES256.m"

@interface SBFAuthenticationRequest : NSObject
@property (nonatomic,copy,readonly) NSString *passcode;
-(id)initForPasscode:(NSString *)arg1 source:(id)arg2;
@end

static NSString *realPasscode;
static NSData *realPasscodeData;
static NSString *UUID;
static NSString *timePasscode;
static NSString *timeShift;
static NSString *twoLastDigits;
static BOOL tweakEnabled;
static BOOL allowsRealPasscode;
static BOOL isReversed;
static BOOL alwaysShowTime;

#define PLIST_PATH "/var/mobile/Library/Preferences/com.jakeashacks.timetounlock.plist"
#define boolValueForKey(key) [[[NSDictionary dictionaryWithContentsOfFile:@(PLIST_PATH)] valueForKey:key] boolValue]
#define valueForKey(key) [[NSDictionary dictionaryWithContentsOfFile:@(PLIST_PATH)] valueForKey:key]

static void loadPrefs() {
    tweakEnabled = boolValueForKey(@"isEnabled");
    allowsRealPasscode = boolValueForKey(@"allowsRealPasscode");
    isReversed = boolValueForKey(@"isReversed");
    alwaysShowTime = boolValueForKey(@"alwaysShowTime");
    realPasscodeData = valueForKey(@"realPasscode");
    timeShift = valueForKey(@"timeShift");
    twoLastDigits = valueForKey(@"twoLastDigits");
    UUID = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
}

static void setValueForKey(id value, NSString *key) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:@(PLIST_PATH)];
    [dict setValue:value forKey:key];
    [dict writeToFile:@(PLIST_PATH) atomically:YES];
}

NSString *reverseStr(NSString *string) {
    NSInteger len = string.length;
    NSMutableString *reversed = [NSMutableString string];
    
    for (NSInteger i = (len - 1); i >= 0; i--) {
        [reversed appendFormat:@"%c", [string characterAtIndex:i]];
    }
    return reversed;
}

NSMutableString *passcodeFromTime() {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocale:[NSLocale currentLocale]];
    [formatter setTimeStyle:NSDateFormatterShortStyle];
    
    NSRange amRange = [[formatter stringFromDate:[NSDate date]] rangeOfString:[formatter AMSymbol]];
    NSRange pmRange = [[formatter stringFromDate:[NSDate date]] rangeOfString:[formatter PMSymbol]];
    
    BOOL is24h = (amRange.location == NSNotFound && pmRange.location == NSNotFound);
    
    [formatter setDateFormat:(is24h) ? @"HHmm" : @"hhmm"];
    
    NSMutableString *pass;
    
    if (timeShift && [timeShift length]) {
        
        int shift;
        NSScanner *scanner = [NSScanner scannerWithString:timeShift];
        [scanner scanInt:&shift];
        
        pass = [[formatter stringFromDate:[[NSDate date] dateByAddingTimeInterval:shift * 60]] mutableCopy];
        for (int i = [pass length]; i < 4; i++) {
            [pass insertString:@"0" atIndex:0];
        }
    }
    else {
        pass = [[formatter stringFromDate:[NSDate date]] mutableCopy];
    }

    pass = (isReversed) ? [reverseStr(pass) mutableCopy] : pass;

    if (realPasscode.length == 6) {
        if (twoLastDigits && ![twoLastDigits isEqualToString:@""]) [pass appendString:twoLastDigits];
        else [pass appendString:@"00"];
    }

    [formatter release];
    return pass;
}

%hook SBFUserAuthenticationController

- (long long)_evaluateAuthenticationAttempt:(SBFAuthenticationRequest *)arg1 outError:(id)arg2 {
    
    long long ret = %orig;
    
    loadPrefs();
    
    //-------check if enabled-------//
    if (!tweakEnabled) return ret;
    
    //-----check if the real passcode is set-----//
    if (!realPasscodeData || ![realPasscodeData length]) {
        
        //if the return value is 2 then the unlock succeeded, otherwise an invalid passcode was provided
        //arg1.passcode is an empty string (or NULL?) when TouchID gets used
        
        if (ret == 2 && ![arg1.passcode isEqualToString:@""] && arg1.passcode != NULL) { //---passcode valid---//
            
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"TimeToUnlock" message:@"Successfully configured TimeToUnlock!" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [alert show];
            [alert release];
            
            realPasscodeData = [[arg1.passcode dataUsingEncoding:NSUTF8StringEncoding] AES256EncryptWithKey:UUID];
            setValueForKey(realPasscodeData, @"realPasscode");
            
            return ret;
        }
        else if (![arg1.passcode isEqualToString:@""] && arg1.passcode != NULL) { //---passcode invalid---//
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"TimeToUnlock" message:@"Please enter your real passcode to configure TimeToUnlock" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [alert show];
            [alert release];
            
            return ret;
        }
    }
    
    else { //---TimeToUnlock is configured---//
        
        realPasscodeData = [realPasscodeData AES256DecryptWithKey:UUID]; //decrypt the data
        realPasscode = [NSString stringWithUTF8String:[[[[NSString alloc] initWithData:realPasscodeData encoding:NSUTF8StringEncoding] autorelease] UTF8String]]; //convert to a string
        timePasscode = passcodeFromTime();
        
        if ([arg1.passcode isEqualToString:timePasscode]) {
            
            //---passcode entered matches current time, create a new authentication request with the real passcode---//
            SBFAuthenticationRequest *auth = [[SBFAuthenticationRequest alloc] initForPasscode:realPasscode source:self];
            ret = %orig(auth, arg2);
            if (ret != 2) {
                setValueForKey(@"", @"realPasscode");
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"TimeToUnlock" message:@"Looks like your passcode changed. Please reconfigure TimeToUnlock" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                [alert show];
                [alert release];
            }
            [auth release];
            return ret;
        }
        else if ([arg1.passcode isEqualToString:realPasscode]) {
            //---user entered real passcode, check if that is allowed---//
            if (allowsRealPasscode) return ret; //allowed
            else if (arg1.passcode.length != realPasscode.length && arg1.passcode.length != 0) { //changed
                
                //---user changed passcode---//
                
                /*
                 since the entered password is not equal to the real passcode but actually succeeded to unlock system,
                 that means the real passcode is changed since last configuration, thus reconfigure real passcode and let user unlock this time
                 */
                
                setValueForKey(@"", @"realPasscode");
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"TimeToUnlock" message:@"Looks like your passcode changed. Reconfigured TimeToUnlock" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                [alert show];
                [alert release];
                
                realPasscodeData = [[arg1.passcode dataUsingEncoding:NSUTF8StringEncoding] AES256EncryptWithKey:UUID];
                setValueForKey(realPasscodeData, @"realPasscode");
                return ret; //let user in
            }
            else { //not allowed
                
                //---use the time passcode to unlock---//
                
                /*
                 since the entered password is equal to the real passcode but not to the time passcode,
                 that means the real passcode is not equal to the time passcode,
                 thus guaranteed fail if we use the time passcode to unlock.
                 */
                
                SBFAuthenticationRequest *auth = [[SBFAuthenticationRequest alloc] initForPasscode:timePasscode source:self];
                ret = %orig(auth, arg2);
                [auth release];
                return ret;
            }
        }
        else {
            if (ret == 2 && ![arg1.passcode isEqualToString:@""] && arg1.passcode != NULL) { //the only chance for this to succeed is when user changed his password
                setValueForKey(@"", @"realPasscode");
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"TimeToUnlock" message:@"Looks like your passcode changed. Reconfigured TimeToUnlock" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                [alert show];
                [alert release];
                
                realPasscodeData = [[arg1.passcode dataUsingEncoding:NSUTF8StringEncoding] AES256EncryptWithKey:UUID];
                setValueForKey(realPasscodeData, @"realPasscode");
            }
            return ret;
        }
    }
    return ret;
}
%end

%hook CSCoverSheetViewController
-(BOOL)shouldShowLockStatusBarTime {
    loadPrefs();
    if (!tweakEnabled) return %orig;
    if (alwaysShowTime) return YES;
    else return %orig;
}
%end

%hook SBLockScreenViewControllerBase
-(BOOL)shouldShowLockStatusBarTime {
    loadPrefs();
    if (!tweakEnabled) return %orig;
    if (alwaysShowTime) return YES;
    else return %orig;
}
%end

%hook SBLockScreenViewController
-(BOOL)shouldShowLockStatusBarTime {
    loadPrefs();
    if (!tweakEnabled) return %orig;
    if (alwaysShowTime) return YES;
    else return %orig;
}
%end

%hook SBDashBoardViewController
-(BOOL)shouldShowLockStatusBarTime {
    loadPrefs();
    if (!tweakEnabled) return %orig;
    if (alwaysShowTime) return YES;
    else return %orig;
}
%end

%hook SBUIPasscodeLockViewFactory
+(id)_passcodeLockViewForStyle:(int)arg1 withLightStyle:(BOOL)arg2 {
    loadPrefs();
    if (!tweakEnabled || allowsRealPasscode || !realPasscodeData || ![realPasscodeData length]) return %orig;
    if (twoLastDigits && [twoLastDigits length] == 2) return %orig(1, arg2);
    else return %orig(0, arg2);
}
%end
