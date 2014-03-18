/*
 Copyright (c) 2001-2009, Kurt Revis.  All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SMMDocument.h"

#import <Cocoa/Cocoa.h>
#import <SnoizeMIDI/SnoizeMIDI.h>
#import <objc/objc-runtime.h>

#import "SMMCombinationInputStream.h"
#import "SMMMonitorWindowController.h"

#pragma mark  - Interface
@interface SMMDocument (Private)

- (void)sourceListDidChange:(NSNotification *)notification;

- (void)setFilterMask:(SMMessageType)newMask;
- (void)setChannelMask:(SMChannelMask)newMask;

- (void)updateVirtualEndpointName;

- (void)autoselectSources;

- (void)historyDidChange:(NSNotification *)notification;
- (void)synchronizeMessagesWithScroll:(BOOL)shouldScroll;

- (void)readingSysEx:(NSNotification *)notification;
- (void)doneReadingSysEx:(NSNotification *)notification;

@end

#pragma mark - Implementation
@implementation SMMDocument

NSString *SMMAutoSelectFirstSourceInNewDocumentPreferenceKey = @"SMMAutoSelectFirstSource";
    // NOTE: The above is obsolete; it's included only for compatibility
NSString *SMMAutoSelectOrdinarySourcesInNewDocumentPreferenceKey = @"SMMAutoSelectOrdinarySources";
NSString *SMMAutoSelectVirtualDestinationInNewDocumentPreferenceKey = @"SMMAutoSelectVirtualDestination";
NSString *SMMAutoSelectSpyingDestinationsInNewDocumentPreferenceKey = @"SMMAutoSelectSpyingDestinations";
NSString *SMMAskBeforeClosingModifiedWindowPreferenceKey = @"SMMAskBeforeClosingModifiedWindow";


- (id)init
{
    NSNotificationCenter *center;

    if (!(self = [super init]))
        return nil;

    center = [NSNotificationCenter defaultCenter];

    stream = [[SMMCombinationInputStream alloc] init];
    [center addObserver:self selector:@selector(readingSysEx:) name:SMInputStreamReadingSysExNotification object:stream];
    [center addObserver:self selector:@selector(doneReadingSysEx:) name:SMInputStreamDoneReadingSysExNotification object:stream];
    [center addObserver:self selector:@selector(sourceListDidChange:) name:SMInputStreamSourceListChangedNotification object:stream];
    [self updateVirtualEndpointName];

    messageFilter = [[SMMessageFilter alloc] init];
    [stream setMessageDestination:messageFilter];
    [messageFilter setFilterMask:SMMessageTypeAllMask];
    [messageFilter setChannelMask:SMChannelMaskAll];

    history = [[SMMessageHistory alloc] init];
    [messageFilter setMessageDestination:history];
    [center addObserver:self selector:@selector(historyDidChange:) name:SMMessageHistoryChangedNotification object:history];

    areSourcesShown = NO;
    isFilterShown = NO;
    missingSourceNames = nil;
    sysExBytesRead = 0;

    // If the user changed the value of this old obsolete preference, bring its value forward to our new preference
	// (the default value was YES)
    if (![[NSUserDefaults standardUserDefaults] boolForKey:SMMAutoSelectFirstSourceInNewDocumentPreferenceKey]) {
		[[NSUserDefaults standardUserDefaults] setBool:NO forKey:SMMAutoSelectOrdinarySourcesInNewDocumentPreferenceKey];
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:SMMAutoSelectFirstSourceInNewDocumentPreferenceKey];
		[[NSUserDefaults standardUserDefaults] synchronize];
	}

    [self autoselectSources];

    [self updateChangeCount:NSChangeCleared];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [stream setMessageDestination:nil];
    [stream release];
    stream = nil;
    [messageFilter setMessageDestination:nil];
    [messageFilter release];
    messageFilter = nil;
    [windowFrameDescription release];
    windowFrameDescription = nil;
    [missingSourceNames release];
    missingSourceNames = nil;
    [history release];
    history = nil;

    [super dealloc];
}

- (void)makeWindowControllers;
{
    NSWindowController *controller;
    
    controller = [[SMMMonitorWindowController alloc] init];
    [self addWindowController:controller];
    [controller release];
}

- (void)showWindows;
{
    [super showWindows];

    if (missingSourceNames) {
        [[self windowControllers] makeObjectsPerformSelector:@selector(couldNotFindSourcesNamed:) withObject:missingSourceNames];
        [missingSourceNames release];
        missingSourceNames = nil;
    }
}

- (void)updateChangeCount:(NSDocumentChangeType)change
{
    // This clears the undo stack whenever we load or save.
    [super updateChangeCount:change];
    if (change == NSChangeCleared)
        [[self undoManager] removeAllActions];
}

- (void)setFileURL:(NSURL*)url
{
    [super setFileURL:url];

    [self updateVirtualEndpointName];
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void *)contextInfo
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:SMMAskBeforeClosingModifiedWindowPreferenceKey]) {
        [super canCloseDocumentWithDelegate:delegate shouldCloseSelector:shouldCloseSelector contextInfo:contextInfo];
    } else {
        // Tell the delegate to close now, regardless of what the document's dirty flag may be.
        // Unfortunately this is not easy in Objective-C...
        void (*objc_msgSendTyped)(id self, SEL _cmd, NSDocument *document, BOOL shouldClose, void *contextInfo) = (void*)objc_msgSend;
        objc_msgSendTyped(delegate, shouldCloseSelector, self, YES /* close now */, contextInfo);
    }
}


#pragma mark - API for SMMMonitorWindowController

- (NSArray *)groupedInputSources
{
    return [stream groupedInputSources];
}

- (NSSet *)selectedInputSources;
{
    return [stream selectedInputSources];
}

- (void)setSelectedInputSources:(NSSet *)inputSources;
{
    NSSet *oldInputSources;

    oldInputSources = [self selectedInputSources];
    if (oldInputSources == inputSources || [oldInputSources isEqual:inputSources])
        return;

    [stream setSelectedInputSources:inputSources];

    [(SMMDocument *)[[self undoManager] prepareWithInvocationTarget:self] setSelectedInputSources:oldInputSources];
    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Selected Sources", @"MIDIMonitor", SMBundleForObject(self), "change source undo action")];

    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeSources)];
}

- (void)revealInputSources:(NSSet *)inputSources;
{
    [[self windowControllers] makeObjectsPerformSelector:@selector(revealInputSources:) withObject:inputSources];
}

- (unsigned int)maxMessageCount;
{
    return [history historySize];
}

- (void)setMaxMessageCount:(unsigned int)newValue;
{
    if (newValue == [history historySize])
        return;

    [[[self undoManager] prepareWithInvocationTarget:self] setMaxMessageCount:[history historySize]];
    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Remembered Events", @"MIDIMonitor", SMBundleForObject(self), "change history limit undo action")];

    [history setHistorySize:newValue];

    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeMaxMessageCount)];
}

- (SMMessageType)filterMask;
{
    return  [messageFilter filterMask];
}

- (void)changeFilterMask:(SMMessageType)maskToChange turnBitsOn:(BOOL)turnBitsOn;
{
    SMMessageType newMask;

    newMask = [messageFilter filterMask];
    if (turnBitsOn)
        newMask |= maskToChange;
    else
        newMask &= ~maskToChange;

    [self setFilterMask:newMask];
}

- (BOOL)isShowingAllChannels;
{
    return ([messageFilter channelMask] == SMChannelMaskAll);
}

- (unsigned int)oneChannelToShow;
{
    // It is possible that something else could have set the mask to show more than one, or zero, channels.
    // We'll just return the lowest enabled channel (1-16), or 0 if no channel is enabled.

    unsigned int channel;
    SMChannelMask mask;

    SMAssert(![self isShowingAllChannels]);
    
    mask = [messageFilter channelMask];

    for (channel = 0; channel < 16; channel++) {
        if (mask & 1)
            return (channel + 1);
        else
            mask >>= 1;
    }
    
    return 0;    
}

- (void)showAllChannels;
{
    [self setChannelMask:SMChannelMaskAll];
}

- (void)showOnlyOneChannel:(unsigned int)channel;
{
    [self setChannelMask:(1 << (channel - 1))];
}

- (BOOL)areSourcesShown;
{
    return areSourcesShown;
}

- (void)setAreSourcesShown:(BOOL)newValue;
{
    if (newValue == areSourcesShown)
        return;

    areSourcesShown = newValue;
    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeSourcesShown)];    
}

- (BOOL)isFilterShown;
{
    return isFilterShown;
}

- (void)setIsFilterShown:(BOOL)newValue;
{
    if (newValue == isFilterShown)
        return;

    isFilterShown = newValue;
    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeFilterShown)];
}

- (BOOL)isVisualiserShown;
{
	return isVisualiserShown;
}

- (void)setIsVisualiserShown:(BOOL)newValue;
{
	if(newValue == isVisualiserShown)
		return;
	
	isVisualiserShown = newValue;
	[[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeVisualiserShown)];
}

- (NSString *)windowFrameDescription;
{
    return windowFrameDescription;
}

- (void)setWindowFrameDescription:(NSString *)value;
{
    if (value == windowFrameDescription || [value isEqualToString:windowFrameDescription])
        return;

    [windowFrameDescription release];
    windowFrameDescription = [value retain];
}

- (void)clearSavedMessages;
{
    if ([[history savedMessages] count] > 0) {
        [history clearSavedMessages];
        
        // Dirty document, since the messages are saved in it
        [self updateChangeCount:NSChangeDone];
    }
}

- (NSArray *)savedMessages;
{
    return [history savedMessages];
}

- (NSPoint)messagesScrollPoint
{
    return messagesScrollPoint;
}

@end


@implementation SMMDocument (Private)

- (void)sourceListDidChange:(NSNotification *)notification;
{
    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeSources)];

    // Also, it's possible that the endpoint names went from being unique to non-unique, so we need
    // to refresh the messages displayed.
    [self synchronizeMessagesWithScroll:NO];
}

- (void)setFilterMask:(SMMessageType)newMask;
{
    SMMessageType oldMask;
    
    oldMask = [messageFilter filterMask];
    if (newMask == oldMask)
        return;

    [[[self undoManager] prepareWithInvocationTarget:self] setFilterMask:oldMask];
    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Filter", @"MIDIMonitor", SMBundleForObject(self), change filter undo action)];

    [messageFilter setFilterMask:newMask];    
    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeFilterControls)];
}

- (void)setChannelMask:(SMChannelMask)newMask;
{
    SMChannelMask oldMask;

    oldMask = [messageFilter channelMask];
    if (newMask == oldMask)
        return;

    [[[self undoManager] prepareWithInvocationTarget:self] setChannelMask:oldMask];
    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Channel", @"MIDIMonitor", SMBundleForObject(self), change filter channel undo action)];

    [messageFilter setChannelMask:newMask];    
    [[self windowControllers] makeObjectsPerformSelector:@selector(synchronizeFilterControls)];
}

- (void)updateVirtualEndpointName;
{
    NSString *applicationName, *endpointName;

    applicationName = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleNameKey];
    endpointName = [NSString stringWithFormat:@"%@ (%@)", applicationName, [self displayName]];
    [stream setVirtualEndpointName:endpointName];
}

- (void)autoselectSources;
{
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSArray *groupedInputSources;
    NSMutableSet *sourcesSet;
    NSArray *sourcesArray;

    groupedInputSources = [self groupedInputSources];
    sourcesSet = [NSMutableSet set];
    
	NSArray *sourcesInputs = [[groupedInputSources objectAtIndex:0] objectForKey:@"sources"];
    if ([defaults boolForKey:SMMAutoSelectOrdinarySourcesInNewDocumentPreferenceKey]) {
        if (groupedInputSources.count > 0 && (sourcesArray = sourcesInputs)) {
			[sourcesSet addObjectsFromArray:sourcesArray];
		}
	} else {
		// Auto selecting the Seaboard by Default:
		for(SMSourceEndpoint* endPoint in sourcesInputs) {
			if([[endPoint longName] isEqualToString:@"Seaboard"]) {
				NSLog(@"Auto Selecting the Seaboard");
				[sourcesSet addObject:endPoint];
				break;
			}
		}
	}
	
    if ([defaults boolForKey:SMMAutoSelectVirtualDestinationInNewDocumentPreferenceKey]) {
        if (groupedInputSources.count > 1 && 
            (sourcesArray = [[groupedInputSources objectAtIndex:1] objectForKey:@"sources"]))
            [sourcesSet addObjectsFromArray:sourcesArray];
    }

	if ([defaults boolForKey:SMMAutoSelectSpyingDestinationsInNewDocumentPreferenceKey]) {
        if (groupedInputSources.count > 2 && 
            (sourcesArray = [[groupedInputSources objectAtIndex:2] objectForKey:@"sources"]))
            [sourcesSet addObjectsFromArray:sourcesArray];
    }
    
    [self setSelectedInputSources:sourcesSet];
}

- (void)historyDidChange:(NSNotification *)notification;
{
    NSNumber *shouldScroll = [[notification userInfo] objectForKey:SMMessageHistoryWereMessagesAdded];
	[self synchronizeMessagesWithScroll: [shouldScroll boolValue]];
}

- (void)synchronizeMessagesWithScroll:(BOOL)shouldScroll
{
    NSArray *windowControllers;
    unsigned int windowControllerIndex;

    windowControllers = [self windowControllers];
    windowControllerIndex = [windowControllers count];
    while (windowControllerIndex--)
        [[windowControllers objectAtIndex:windowControllerIndex] synchronizeMessagesWithScrollToBottom:shouldScroll];
}

- (void)readingSysEx:(NSNotification *)notification;
{
    sysExBytesRead = [[[notification userInfo] objectForKey:@"length"] unsignedIntValue];
    
    // We want multiple updates to get coalesced, so only queue it once
    if (!isSysExUpdateQueued) {
        isSysExUpdateQueued = YES;
        [self performSelector:@selector(updateSysExReadIndicators) withObject:nil afterDelay:0];
    }
}

- (void)updateSysExReadIndicators
{
    isSysExUpdateQueued = NO;
    [[self windowControllers] makeObjectsPerformSelector:@selector(updateSysExReadIndicatorWithBytes:) withObject:[NSNumber numberWithUnsignedInt:sysExBytesRead]];
}

- (void)doneReadingSysEx:(NSNotification *)notification;
{
    NSNumber *number = [[notification userInfo] objectForKey:@"length"];
    sysExBytesRead = [number unsignedIntValue];
    
    if (isSysExUpdateQueued) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSysExReadIndicators) object:nil];
        isSysExUpdateQueued = NO;
    }
    
    [[self windowControllers] makeObjectsPerformSelector:@selector(stopSysExReadIndicatorWithBytes:) withObject:number];
}

@end
