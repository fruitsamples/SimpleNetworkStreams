/*
    File:       ReceiveServerController.m

    Contains:   Manages the receive server tab.

    Written by: DTS

    Copyright:  Copyright (c) 2009 Apple Inc. All Rights Reserved.

    Disclaimer: IMPORTANT: This Apple software is supplied to you by Apple Inc.
                ("Apple") in consideration of your agreement to the following
                terms, and your use, installation, modification or
                redistribution of this Apple software constitutes acceptance of
                these terms.  If you do not agree with these terms, please do
                not use, install, modify or redistribute this Apple software.

                In consideration of your agreement to abide by the following
                terms, and subject to these terms, Apple grants you a personal,
                non-exclusive license, under Apple's copyrights in this
                original Apple software (the "Apple Software"), to use,
                reproduce, modify and redistribute the Apple Software, with or
                without modifications, in source and/or binary forms; provided
                that if you redistribute the Apple Software in its entirety and
                without modifications, you must retain this notice and the
                following text and disclaimers in all such redistributions of
                the Apple Software. Neither the name, trademarks, service marks
                or logos of Apple Inc. may be used to endorse or promote
                products derived from the Apple Software without specific prior
                written permission from Apple.  Except as expressly stated in
                this notice, no other rights or licenses, express or implied,
                are granted by Apple herein, including but not limited to any
                patent rights that may be infringed by your derivative works or
                by other works in which the Apple Software may be incorporated.

                The Apple Software is provided by Apple on an "AS IS" basis. 
                APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING
                WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT,
                MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING
                THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN
                COMBINATION WITH YOUR PRODUCTS.

                IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT,
                INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
                TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
                DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY
                OUT OF THE USE, REPRODUCTION, MODIFICATION AND/OR DISTRIBUTION
                OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY
                OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR
                OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF
                SUCH DAMAGE.

*/

#import "ReceiveServerController.h"

#import "AppDelegate.h"

#include <CFNetwork/CFNetwork.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

@interface ReceiveServerController ()

// Properties that don't need to be seen by the outside world.

@property (nonatomic, readonly) BOOL                isStarted;
@property (nonatomic, readonly) BOOL                isReceiving;
@property (nonatomic, retain)   NSNetService *      netService;
@property (nonatomic, assign)   CFSocketRef         listeningSocket;
@property (nonatomic, retain)   NSInputStream *     networkStream;
@property (nonatomic, retain)   NSOutputStream *    fileStream;
@property (nonatomic, copy)     NSString *          filePath;

// Forward declarations

- (void)_stopServer:(NSString *)reason;

@end

@implementation ReceiveServerController

#pragma mark * Status management

// These methods are used by the core transfer code to update the UI.

- (void)_serverDidStartOnPort:(int)port
{
    assert( (port > 0) && (port < 65536) );
    self.statusLabel.text = [NSString stringWithFormat:@"Started on port %d", port];
    [self.startOrStopButton setTitle:@"Stop" forState:UIControlStateNormal];
    self.tabBarItem.image = [UIImage imageNamed:@"receiveserverOn.png"];
}

- (void)_serverDidStopWithReason:(NSString *)reason
{
    if (reason == nil) {
        reason = @"Stopped";
    }
    self.statusLabel.text = reason;
    [self.startOrStopButton setTitle:@"Start" forState:UIControlStateNormal];
    self.tabBarItem.image = [UIImage imageNamed:@"receiveserverOff.png"];
}

- (void)_receiveDidStart
{
    self.statusLabel.text = @"Receiving";
    self.imageView.image = [UIImage imageNamed:@"NoImage.png"];
    [self.activityIndicator startAnimating];
    [[AppDelegate sharedAppDelegate] didStartNetworking];
}

- (void)_updateStatus:(NSString *)statusString
{
    assert(statusString != nil);
    self.statusLabel.text = statusString;
}

- (void)_receiveDidStopWithStatus:(NSString *)statusString
{
    if (statusString == nil) {
        assert(self.filePath != nil);
        self.imageView.image = [UIImage imageWithContentsOfFile:self.filePath];
        statusString = @"Receive succeeded";
    }
    self.statusLabel.text = statusString;
    [self.activityIndicator stopAnimating];
    [[AppDelegate sharedAppDelegate] didStopNetworking];
}

#pragma mark * Core transfer code

// This is the code that actually does the networking.

@synthesize netService      = _netService;
@synthesize networkStream   = _networkStream;
@synthesize listeningSocket = _listeningSocket;
@synthesize fileStream      = _fileStream;
@synthesize filePath        = _filePath;

- (BOOL)isStarted
{
    return (self.netService != nil);
}

- (BOOL)isReceiving
{
    return (self.networkStream != nil);
}

// Have to write our own setter for listeningSocket because CF gets grumpy 
// if you message NULL.

- (void)setListeningSocket:(CFSocketRef)newValue
{
    if (newValue != self->_listeningSocket) {
        if (self->_listeningSocket != NULL) {
            CFRelease(self->_listeningSocket);
        }
        self->_listeningSocket = newValue;
        if (self->_listeningSocket != NULL) {
            CFRetain(self->_listeningSocket);
        }
    }
}

- (void)_startReceive:(int)fd
{
    CFReadStreamRef     readStream;
    
    assert(fd >= 0);

    assert(self.networkStream == nil);      // can't already be receiving
    assert(self.fileStream == nil);         // ditto
    assert(self.filePath == nil);           // ditto

    // Open a stream for the file we're going to receive into.

    self.filePath = [[AppDelegate sharedAppDelegate] pathForTemporaryFileWithPrefix:@"Receive"];
    assert(self.filePath != nil);

    self.fileStream = [NSOutputStream outputStreamToFileAtPath:self.filePath append:NO];
    assert(self.fileStream != nil);
    
    [self.fileStream open];

    // Open a stream based on the existing socket file descriptor.  Then configure 
    // the stream for async operation.

    CFStreamCreatePairWithSocket(NULL, fd, &readStream, NULL);
    assert(readStream != NULL);
    
    self.networkStream = (NSInputStream *) readStream;
    
    CFRelease(readStream);

    [self.networkStream setProperty:(id)kCFBooleanTrue forKey:(NSString *)kCFStreamPropertyShouldCloseNativeSocket];

    self.networkStream.delegate = self;
    [self.networkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    
    [self.networkStream open];

    // Tell the UI we're receiving.
    
    [self _receiveDidStart];
}

- (void)_stopReceiveWithStatus:(NSString *)statusString
{
    if (self.networkStream != nil) {
        self.networkStream.delegate = nil;
        [self.networkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        [self.networkStream close];
        self.networkStream = nil;
    }
    if (self.fileStream != nil) {
        [self.fileStream close];
        self.fileStream = nil;
    }
    [self _receiveDidStopWithStatus:statusString];
    self.filePath = nil;
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
    // An NSStream delegate callback that's called when events happen on our 
    // network stream.
{
    #pragma unused(aStream)
    assert(aStream == self.networkStream);

    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            [self _updateStatus:@"Opened connection"];
        } break;
        case NSStreamEventHasBytesAvailable: {
            NSInteger       bytesRead;
            uint8_t         buffer[32768];

            [self _updateStatus:@"Receiving"];

            // Pull some data off the network.
            
            bytesRead = [self.networkStream read:buffer maxLength:sizeof(buffer)];
            if (bytesRead == -1) {
                [self _stopReceiveWithStatus:@"Network read error"];
            } else if (bytesRead == 0) {
                [self _stopReceiveWithStatus:nil];
            } else {
                NSInteger   bytesWritten;
                NSInteger   bytesWrittenSoFar;

                // Write to the file.
                
                bytesWrittenSoFar = 0;
                do {
                    bytesWritten = [self.fileStream write:&buffer[bytesWrittenSoFar] maxLength:bytesRead - bytesWrittenSoFar];
                    assert(bytesWritten != 0);
                    if (bytesWritten == -1) {
                        [self _stopReceiveWithStatus:@"File write error"];
                        break;
                    } else {
                        bytesWrittenSoFar += bytesWritten;
                    }
                } while (bytesWrittenSoFar != bytesRead);
            }
        } break;
        case NSStreamEventHasSpaceAvailable: {
            assert(NO);     // should never happen for the output stream
        } break;
        case NSStreamEventErrorOccurred: {
            [self _stopReceiveWithStatus:@"Stream open error"];
        } break;
        case NSStreamEventEndEncountered: {
            // ignore
        } break;
        default: {
            assert(NO);
        } break;
    }
}

- (void)_acceptConnection:(int)fd
{
    int     junk;

    // If we already have a connection, reject this new one.  This is one of the 
    // big simplifying assumptions in this code.  A real server should handle 
    // multiple simultaneous connections.

    if ( self.isReceiving ) {
        junk = close(fd);
        assert(junk == 0);
    } else {
        [self _startReceive:fd];
    }
}

static void AcceptCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
    // Called by CFSocket when someone connects to our listening socket.  
    // This implementation just bounces the request up to Objective-C.
{
    ReceiveServerController *  obj;
    
    #pragma unused(type)
    assert(type == kCFSocketAcceptCallBack);
    #pragma unused(address)
    // assert(address == NULL);
    assert(data != NULL);
    
    obj = (ReceiveServerController *) info;
    assert(obj != nil);

    #pragma unused(s)
    assert(s == obj->_listeningSocket);
    
    [obj _acceptConnection:*(int *)data];
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict
    // A NSNetService delegate callback that's called if our Bonjour registration 
    // fails.  We respond by shutting down the server.
    //
    // This is another of the big simplifying assumptions in this sample. 
    // A real server would use the real name of the device for registrations, 
    // and handle automatically renaming the service on conflicts.  A real 
    // client would allow the user to browse for services.  To simplify things 
    // we just hard-wire the service name in the client and, in the server, fail 
    // if there's a service name conflict.
{
    #pragma unused(sender)
    assert(sender == self.netService);
    #pragma unused(errorDict)
    
    [self _stopServer:@"Registration failed"];
}

- (void)_startServer
{
    BOOL        success;
    int         err;
    int         fd;
    int         junk;
    struct sockaddr_in addr;
    int         port;
    
    // Create a listening socket and use CFSocket to integrate it into our 
    // runloop.  We bind to port 0, which causes the kernel to give us 
    // any free port, then use getsockname to find out what port number we 
    // actually got.

    port = 0;
    
    fd = socket(AF_INET, SOCK_STREAM, 0);
    success = (fd != -1);
    
    if (success) {
        memset(&addr, 0, sizeof(addr));
        addr.sin_len    = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port   = 0;
        addr.sin_addr.s_addr = INADDR_ANY;
        err = bind(fd, (const struct sockaddr *) &addr, sizeof(addr));
        success = (err == 0);
    }
    if (success) {
        err = listen(fd, 5);
        success = (err == 0);
    }
    if (success) {
        socklen_t   addrLen;

        addrLen = sizeof(addr);
        err = getsockname(fd, (struct sockaddr *) &addr, &addrLen);
        success = (err == 0);
        
        if (success) {
            assert(addrLen == sizeof(addr));
            port = ntohs(addr.sin_port);
        }
    }
    if (success) {
        CFSocketContext context = { 0, self, NULL, NULL, NULL };
        
        self.listeningSocket = CFSocketCreateWithNative(
            NULL, 
            fd, 
            kCFSocketAcceptCallBack, 
            AcceptCallback, 
            &context
        );
        success = (self.listeningSocket != NULL);
        
        if (success) {
            CFRunLoopSourceRef  rls;
            
            CFRelease(self.listeningSocket);        // to balance the create

            fd = -1;        // listeningSocket is now responsible for closing fd

            rls = CFSocketCreateRunLoopSource(NULL, self.listeningSocket, 0);
            assert(rls != NULL);
            
            CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
            
            CFRelease(rls);
        }
    }

    // Now register our service with Bonjour.  See the comments in -netService:didNotPublish: 
    // for more info about this simplifying assumption.

    if (success) {
        self.netService = [[[NSNetService alloc] initWithDomain:@"local." type:@"_x-SNSUpload._tcp." name:@"Test" port:port] autorelease];
        success = (self.netService != nil);
    }
    if (success) {
        self.netService.delegate = self;
        
        [self.netService publishWithOptions:NSNetServiceNoAutoRename];
        
        // continues in -netServiceDidPublish: or -netService:didNotPublish: ...
    }
    
    // Clean up after failure.
    
    if ( success ) {
        assert(port != 0);
        [self _serverDidStartOnPort:port];
    } else {
        [self _stopServer:@"Start failed"];
        if (fd != -1) {
            junk = close(fd);
            assert(junk == 0);
        }
    }
}

- (void)_stopServer:(NSString *)reason
{
    if (self.isReceiving) {
        [self _stopReceiveWithStatus:@"Cancelled"];
    }
    if (self.netService != nil) {
        [self.netService stop];
        self.netService = nil;
    }
    if (self.listeningSocket != NULL) {
        CFSocketInvalidate(self.listeningSocket);
        self.listeningSocket = NULL;
    }
    [self _serverDidStopWithReason:reason];
}


#pragma mark * Actions

- (IBAction)startOrStopAction:(id)sender
{
    #pragma unused(sender)
    if (self.isStarted) {
        [self _stopServer:nil];
    } else {
        [self _startServer];
    }
}

#pragma mark * View controller boilerplate

@synthesize imageView         = _imageView;
@synthesize statusLabel       = _statusLabel;
@synthesize activityIndicator = _activityIndicator;
@synthesize startOrStopButton = _startOrStopButton;

- (void)viewDidLoad
{
    [super viewDidLoad];
    assert(self.imageView != nil);
    assert(self.statusLabel != nil);
    assert(self.activityIndicator != nil);
    assert(self.startOrStopButton != nil);
    
    self.activityIndicator.hidden = YES;
    self.statusLabel.text = @"Tap Start to start the server";
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    self.imageView = nil;
    self.statusLabel = nil;
    self.activityIndicator = nil;
    self.startOrStopButton = nil;
}

- (void)dealloc
{
    [self _stopServer:nil];
    
    [self->_imageView release];
    [self->_statusLabel release];
    [self->_activityIndicator release];
    [self->_startOrStopButton release];

    [super dealloc];
}

@end
