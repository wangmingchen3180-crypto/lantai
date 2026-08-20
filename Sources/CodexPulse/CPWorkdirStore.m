#import "CPWorkdirStore.h"

@implementation CPWorkdirEntry
@end

@implementation CPWorkdirStore {
    NSUserDefaults *_defaults;
}

+ (NSString *)defaultsKey {
    return @"control.workdirs.v1";
}

- (instancetype)initWithSuiteName:(NSString *)suiteName {
    NSUserDefaults *defaults = suiteName.length
        ? [[NSUserDefaults alloc] initWithSuiteName:suiteName]
        : NSUserDefaults.standardUserDefaults;
    return [self initWithDefaults:defaults];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;
    _defaults = defaults ?: NSUserDefaults.standardUserDefaults;
    return self;
}

static NSString *CPWorkdirTrim(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    return [((NSString *)value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *CPWorkdirNormalizedPath(NSString *path) {
    if (!path.length) return path;
    return path.stringByStandardizingPath;
}

- (NSArray<CPWorkdirEntry *> *)allEntries {
    id raw = [_defaults objectForKey:[self.class defaultsKey]];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<CPWorkdirEntry *> *out = NSMutableArray.array;
    NSMutableSet<NSString *> *seen = NSMutableSet.set;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (id item in raw) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        NSString *workdirID = CPWorkdirTrim(row[@"workdirID"]);
        NSString *name = CPWorkdirTrim(row[@"name"]);
        NSString *path = CPWorkdirTrim(row[@"path"]);
        if (!workdirID.length || !name.length || !path.length) continue;
        if ([seen containsObject:workdirID]) continue;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
        [seen addObject:workdirID];
        CPWorkdirEntry *entry = CPWorkdirEntry.new;
        entry.workdirID = workdirID;
        entry.name = name;
        entry.path = path;
        [out addObject:entry];
    }
    return out;
}

- (CPWorkdirEntry *)entryWithID:(NSString *)workdirID {
    workdirID = CPWorkdirTrim(workdirID);
    if (!workdirID.length) return nil;
    for (CPWorkdirEntry *entry in [self allEntries]) {
        if ([entry.workdirID isEqualToString:workdirID]) return entry;
    }
    return nil;
}

- (void)saveEntries:(NSArray<CPWorkdirEntry *> *)entries {
    NSMutableArray *rows = NSMutableArray.array;
    for (CPWorkdirEntry *entry in entries) {
        [rows addObject:@{
            @"workdirID": entry.workdirID ?: @"",
            @"name": entry.name ?: @"",
            @"path": entry.path ?: @"",
        }];
    }
    [_defaults setObject:rows forKey:[self.class defaultsKey]];
}

- (CPWorkdirEntry *)addPath:(NSString *)path name:(NSString *)name {
    path = CPWorkdirNormalizedPath(CPWorkdirTrim(path));
    name = CPWorkdirTrim(name);
    if (!path.length) return nil;
    if (!name.length) name = path.lastPathComponent;
    if (!name.length) return nil;

    NSArray<CPWorkdirEntry *> *current = [self allEntries];
    NSString *wanted = path;
    for (CPWorkdirEntry *entry in current) {
        if ([CPWorkdirNormalizedPath(entry.path) isEqualToString:wanted]) return entry;
    }

    CPWorkdirEntry *entry = CPWorkdirEntry.new;
    entry.workdirID = NSUUID.UUID.UUIDString;
    entry.name = name;
    entry.path = path;
    NSMutableArray<CPWorkdirEntry *> *next = [current mutableCopy];
    [next addObject:entry];
    [self saveEntries:next];
    return entry;
}

- (BOOL)renameEntry:(NSString *)workdirID to:(NSString *)name {
    workdirID = CPWorkdirTrim(workdirID);
    name = CPWorkdirTrim(name);
    if (!workdirID.length || !name.length) return NO;
    NSArray<CPWorkdirEntry *> *current = [self allEntries];
    BOOL found = NO;
    NSMutableArray<CPWorkdirEntry *> *next = NSMutableArray.array;
    for (CPWorkdirEntry *entry in current) {
        if ([entry.workdirID isEqualToString:workdirID]) {
            entry.name = name;
            found = YES;
        }
        [next addObject:entry];
    }
    if (!found) return NO;
    [self saveEntries:next];
    return YES;
}

- (BOOL)removeEntry:(NSString *)workdirID {
    workdirID = CPWorkdirTrim(workdirID);
    if (!workdirID.length) return NO;
    NSArray<CPWorkdirEntry *> *current = [self allEntries];
    NSMutableArray<CPWorkdirEntry *> *next = NSMutableArray.array;
    BOOL found = NO;
    for (CPWorkdirEntry *entry in current) {
        if ([entry.workdirID isEqualToString:workdirID]) {
            found = YES;
            continue;
        }
        [next addObject:entry];
    }
    if (!found) return NO;
    [self saveEntries:next];
    return YES;
}

@end
