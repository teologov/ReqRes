//
//  UserPreferences.swift
//  ReqRes
//
//  Created by OloApps on 15.06.2021.
//  Stores preferences via property wrappers
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
//
//  Licensed under the Functional Source License, Version 1.1 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://fsl.software/
//
//  This software is licensed under the Functional Source License, Version 1.1,
//  with Apache License, Version 2.0 as the Future License. The Licensed Work
//  will become available under Apache-2.0 two years from the date this
//  software is first publicly distributed.
//
//  See LICENSE.md in the repository root for full license text.
//  NOT USED

/*
 // source: https://www.avanderlee.com/swift/property-wrappers/
 // usage example
 // 1. Add the property:
 
 @UserDefault(key: "isVPNEnabled", defaultValue: false)
 static var isVPNEnabled: Bool?
 // subscribe to change
 let subscription = UserDefaults.$isVPNEnabled.sink { isVPNEnabled in
     print("isVPNEnabled: \(isVPNEnabled)")
 }
 UserDefaults.isVPNEnabled = true
 // Prints: isVPNEnabled: true
 */

import Foundation
import Combine

/// Allows to match for optionals with generics that are defined as non-optional.
public protocol AnyOptional {
    /// Returns `true` if `nil`, otherwise `false`.
    var isNil: Bool { get }
}
extension Optional: AnyOptional {
    public var isNil: Bool { self == nil }
}

@propertyWrapper
struct UserDefault<Value> {
    let key: String
    let defaultValue: Value
    var container: UserDefaults = UserDefaults.standard
    private let publisher = PassthroughSubject<Value, Never>()
    
    var wrappedValue: Value {
        get {
            return container.object(forKey: key) as? Value ?? defaultValue
        }
        set {
            // Check whether we're dealing with an optional and remove the object if the new value is nil.
            if let optional = newValue as? AnyOptional, optional.isNil {
                container.removeObject(forKey: key)
            } else {
                container.set(newValue, forKey: key)
                container.synchronize()
            }
            publisher.send(newValue)
        }
    }

    var projectedValue: AnyPublisher<Value, Never> {
        return publisher.eraseToAnyPublisher()
    }
}

extension UserDefaults {
    /// controls the VPN state, via the Play/Pause button in the toolbar
    // @UserDefault(key: "isVPNEnabled", defaultValue: false)
    // static var isVPNEnabled: Bool?
}
