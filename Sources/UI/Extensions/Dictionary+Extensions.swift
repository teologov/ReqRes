//
//  Dictionary+Extensions.swift
//  ReqRes
//
//  Created by OloApps on 30.06.2023.
//
//  Copyright © 2025 OloApps. All rights reserved.
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
//

import Foundation

extension Dictionary {
    public static func fromJson(_ json:String) -> Dictionary {
        let jsonData:Data = json.data(using: .utf8)!
        let dict = try? JSONSerialization.jsonObject(with: jsonData, options: .mutableContainers)

        if dict != nil {
            return dict as! Dictionary
        }
        return Dictionary()
    }
}
