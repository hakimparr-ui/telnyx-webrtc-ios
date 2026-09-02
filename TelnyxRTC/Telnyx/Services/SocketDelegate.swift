//
//  SocketDelegate.swift
//  TelnyxRTC
//
//  Created by Guillermo Battistel on 02/03/2021.
//  Copyright © 2021 Telnyx LLC. All rights reserved.
//

import Foundation

protocol SocketDelegate: AnyObject {
    func onSocketConnected(socket: Socket)
    func onSocketDisconnected(socket: Socket, reconnect: Bool, region: Region?)
    func onSocketError(socket: Socket, error: Error)
    func onMessageReceived(socket: Socket, message: String)
}
