//
//  VideoCache.swift
//  Aerial
//
//  Created by John Coates on 10/29/15.
//  Copyright © 2015 John Coates. All rights reserved.
//

import Foundation
import AVFoundation


class VideoCache {
    var videoData:NSData
    var mutableVideoData:NSMutableData?
    
    var loading:Bool
    var loadedRanges:[NSRange] = []
    let URL:NSURL
    
    
    init(URL:NSURL) {
        videoData = NSData()
        loading = true
        self.URL = URL
        loadCachedVideoIfPossible();
    }
    
    // MARK: - Data Adding
    
    func receivedContentLength(contentLength:Int) {
        if loading == false {
            return;
        }
        
        if mutableVideoData != nil {
            return;
        }
        
        mutableVideoData = NSMutableData(length: contentLength)
        videoData = mutableVideoData!;
    }
    
    func receivedData(data:NSData, atRange range:NSRange) {
        guard let mutableVideoData = mutableVideoData else {
            NSLog("Aerial Error: Received data without having mutable video data");
            return;
        }
        
        mutableVideoData.replaceBytesInRange(range, withBytes: data.bytes);
        loadedRanges.append(range);
        
        consolidateLoadedRanges();
        
        debugLog("loaded ranges: \(loadedRanges)");
        if loadedRanges.count == 1 {
            let range = loadedRanges[0]
            debugLog("checking if range \(range) matches length \(mutableVideoData.length)");
            if range.location == 0 && range.length == mutableVideoData.length {
                // done loading, save
                saveCachedVideo();
            }
        }
    }
    
    // MARK: - Save / Load Cache
    
    var videoCachePath:String? {
        get {
            let fileManager = NSFileManager.defaultManager()
            let cachePaths = NSSearchPathForDirectoriesInDomains(.CachesDirectory,
                .UserDomainMask,
                true);
            
            if cachePaths.count == 0 {
                NSLog("Aerial Error: Couldn't find cache paths!");
                return nil;
            }
            
            let userCacheDirectory = cachePaths[0] as NSString;
            let appCacheDirectory = userCacheDirectory.stringByAppendingPathComponent("Aerial") as NSString;
            
            if fileManager.fileExistsAtPath(appCacheDirectory as String) == false {
                do {
                    try fileManager.createDirectoryAtPath(appCacheDirectory as String, withIntermediateDirectories: false, attributes: nil);
                }
                catch let error {
                    NSLog("Aerial Error: Couldn't create cache directory: \(error)");
                    return nil;
                }
            }
            
            guard let filename = URL.lastPathComponent else {
                NSLog("Aerial Error: Couldn't get filename from URL for cache.");
                return nil;
            }
            
            let videoCachePath = appCacheDirectory.stringByAppendingPathComponent(filename);
            return videoCachePath
        }
    }
    
    func saveCachedVideo() {
        let fileManager = NSFileManager.defaultManager()
        
        guard let videoCachePath = videoCachePath else {
            NSLog("Aerial Error: Couldn't save cache file");
            return;
        }
        
        guard fileManager.fileExistsAtPath(videoCachePath) == false else {
            NSLog("Aerial Error: Cache file \(videoCachePath) already exists.");
            return;
        }
        
        loading = false;
        guard let mutableVideoData = mutableVideoData else {
            NSLog("Aerial Error: Missing video data for save.");
            return;
        }
        
        do {
            try mutableVideoData.writeToFile(videoCachePath, options: .AtomicWrite)
        }
        catch let error {
            NSLog("Aerial Error: Couldn't write cache file: \(error)");
        }
    }
    
    func loadCachedVideoIfPossible() {
        let fileManager = NSFileManager.defaultManager()
        
        guard let videoCachePath = self.videoCachePath else {
            NSLog("Aerial Error: Couldn't load cache file.");
            return;
        }
        
        if fileManager.fileExistsAtPath(videoCachePath) == false {
            return;
        }
        
        guard let videoData = NSData(contentsOfFile: videoCachePath) else {
            NSLog("Aerial Error: NSData failed to load cache file \(videoCachePath)")
            return;
        }
        
        self.videoData = videoData;
        loading = false;
        debugLog("cached video file with length: \(self.videoData.length)");
    }
    
    // MARK: - Fulfilling cache
    
    func fulfillLoadingRequest(loadingRequest:AVAssetResourceLoadingRequest) -> Bool {
        guard let dataRequest = loadingRequest.dataRequest else {
            NSLog("Aerial Error: Missing data request for \(loadingRequest)");
            return false;
        }
        
        let requestedOffset = Int(dataRequest.requestedOffset)
        let requestedLength = Int(dataRequest.requestedLength)
        
        let range = NSMakeRange(requestedOffset, requestedLength);
        
        let data = videoData.subdataWithRange(range);
        
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            
            self.fillInContentInformation(loadingRequest);
            
            dataRequest.respondWithData(data);
            loadingRequest.finishLoading();
        }
        
        return true;
    }
    
    func fillInContentInformation(loadingRequest:AVAssetResourceLoadingRequest) {
        
        guard let contentInformationRequest = loadingRequest.contentInformationRequest else {
            return;
        }
        
        let contentType:String = kUTTypeQuickTimeMovie as String;
        
        contentInformationRequest.byteRangeAccessSupported = true;
        contentInformationRequest.contentType = contentType;
        contentInformationRequest.contentLength = Int64(videoData.length);
    }
    
    // MARK: - Cache Checking
    
    // Whether the video cache can fulfill this request
    func canFulfillLoadingRequest(loadingRequest:AVAssetResourceLoadingRequest) -> Bool {
        
        if (loading == false) {
            return true;
        }
        
        guard let dataRequest = loadingRequest.dataRequest else {
            NSLog("Aerial Error: Missing data request for \(loadingRequest)");
            return false;
        }
        
        let requestedOffset = Int(dataRequest.requestedOffset)
        let requestedLength = Int(dataRequest.requestedLength)
        let requestedEnd = requestedOffset + requestedLength
        
        for range in loadedRanges {
            let rangeStart = range.location
            let rangeEnd = range.location + range.length
            
            if requestedOffset >= rangeStart && requestedEnd <= rangeEnd {
                return true;
            }
        }
        
        return false;
    }
    
    
    // MARK: - Consolidating
    
    func consolidateLoadedRanges() {
        var consolidatedRanges:[NSRange] = []
        
        let sortedRanges = loadedRanges.sort { $0.location < $1.location }
        
        var previousRange:NSRange?
        var lastIndex:Int?
        for range in sortedRanges {
            if let lastRange:NSRange = previousRange {
                let lastRangeEndOffset = lastRange.location + lastRange.length
                
                // check if range can be consumed by lastRange
                // or if they're at each other's edges if it can be merged
                
                if lastRangeEndOffset >= range.location {
                    let endOffset = range.location + range.length;
                    
                    // check if this range's end offset is larger than lastRange's
                    if endOffset > lastRangeEndOffset {
                        previousRange!.length = endOffset - lastRange.location;
                        
                        // replace lastRange in array with new value
                        consolidatedRanges.removeAtIndex(lastIndex!);
                        consolidatedRanges.append(previousRange!);
                        continue;
                    }
                    else {
                        // skip adding this to the array, previous range is already bigger
                        debugLog("skipping add of \(range)");
                        continue;
                    }
                }
            }
            
            lastIndex = consolidatedRanges.count
            previousRange = range
            consolidatedRanges.append(range);
        }
        loadedRanges = consolidatedRanges;
    }
}